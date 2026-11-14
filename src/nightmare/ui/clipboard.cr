# nightmare/src/nightmare/ui/clipboard.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "base64"
require "path"
require "mantle"
require "../config"
require "../exceptions"
require "../tools/guard"
require "../tools/read_only"

module Nightmare::UI
  record PendingImage,
    label : String,
    mime : String,
    size_bytes : Int64,
    base64 : String

  module Clipboard
    extend self

    PREFERRED_MIMES = ["image/png", "image/jpeg", "image/webp", "image/gif"]

    class_property test_image_provider : Proc(Tuple(Bytes, String)?)? = nil
    class_property test_text_provider : Proc(String?)? = nil

    def image_path?(path : String) : Bool
      clean = normalize_pasted_path(path)
      Nightmare::Config::IMAGE_EXTENSIONS.includes?(File.extname(clean).downcase)
    end

    def normalize_pasted_path(raw : String) : String
      trimmed = raw.strip
      if (trimmed.starts_with?('"') && trimmed.ends_with?('"')) ||
         (trimmed.starts_with?('\'') && trimmed.ends_with?('\''))
        trimmed = trimmed[1...-1] if trimmed.size >= 2
      end
      if trimmed.starts_with?("file://")
        trimmed = trimmed[7..]
        trimmed = trimmed.gsub("%20", " ")
      end
      trimmed
    end

    def detect_mime(bytes : Bytes, path_hint : String? = nil) : String?
      Mantle::Support::Image.detect_mime(bytes, path_hint)
    end

    def load_file(path : String, guard : Nightmare::Tools::Guard? = nil) : PendingImage
      clean = normalize_pasted_path(path)
      full_path = if g = guard
        g.resolve_read(clean)
      else
        File.expand_path(clean)
      end

      unless File.exists?(full_path) && !File.directory?(full_path)
        raise Nightmare::Error.new("Image file not found: #{path}")
      end

      file_bytes = File.size(full_path)
      if file_bytes <= 0
        raise Nightmare::Error.new("Image file is empty: #{path}")
      end
      if file_bytes > Nightmare::Config::MAX_IMAGE_BYTES
        raise Nightmare::Error.new("Image '#{path}' (#{file_bytes} bytes) exceeds maximum image size of #{Nightmare::Config::MAX_IMAGE_BYTES} bytes.")
      end

      header = File.open(full_path, "rb") do |f|
        buf = Bytes.new(16)
        n = f.read(buf)
        buf[0, n]
      end
      mime = detect_mime(header, full_path)
      unless mime
        raise Nightmare::Error.new("Unsupported image format: #{path}")
      end

      raw_slice = File.read(full_path).to_slice
      b64, final_mime, final_size = Mantle::Support::Image.encode_base64(raw_slice, mime)
      PendingImage.new(
        label: File.basename(full_path),
        mime: final_mime,
        size_bytes: final_size,
        base64: b64
      )
    end

    def capture_image(custom_provider : Proc(Tuple(Bytes, String)?)? = nil) : PendingImage?
      if provider = (custom_provider || @@test_image_provider)
        result = provider.call
        return nil unless result
        bytes, mime = result
        return nil if bytes.empty? || bytes.size > Nightmare::Config::MAX_IMAGE_BYTES
        detected = detect_mime(bytes) || mime
        b64, final_mime, final_size = Mantle::Support::Image.encode_base64(bytes, detected)
        return PendingImage.new(
          label: "clipboard",
          mime: final_mime,
          size_bytes: final_size,
          base64: b64
        )
      end

      if (wl = ENV["WAYLAND_DISPLAY"]?) && !wl.empty?
        if img = capture_wayland_image
          return img
        end
      end

      if (disp = ENV["DISPLAY"]?) && !disp.empty?
        if img = capture_x11_image
          return img
        end
      end

      nil
    end

    def capture_text : String?
      if provider = @@test_text_provider
        return provider.call
      end

      if (wl = ENV["WAYLAND_DISPLAY"]?) && !wl.empty?
        if txt = run_capture_text("wl-paste", ["--no-newline"])
          return txt
        end
      end

      if (disp = ENV["DISPLAY"]?) && !disp.empty?
        if txt = run_capture_text("xclip", ["-selection", "clipboard", "-o"])
          return txt
        end
        if txt = run_capture_text("xsel", ["-ob"])
          return txt
        end
      end

      nil
    end

    def extract_inline_images(input : String, guard : Nightmare::Tools::Guard) : Tuple(String, Array(PendingImage))
      extracted = [] of PendingImage
      cleaned = input.gsub(/(^|\s)@(?:"([^"]+)"|'([^']+)'|(\S+))/) do |match_str, md|
        prefix = md[1]
        raw_path = md[2]? || md[3]? || md[4]? || ""
        if image_path?(raw_path)
          begin
            img = load_file(raw_path, guard)
            extracted << img
            "#{prefix}[Image: #{img.label}]"
          rescue
            match_str
          end
        else
          match_str
        end
      end
      {cleaned, extracted}
    end

    def format_bytes(bytes : Int64) : String
      if bytes < 1024
        "#{bytes} B"
      elsif bytes < 1024 * 1024
        "#{(bytes / 1024.0).round(1)} KB"
      else
        "#{(bytes / (1024.0 * 1024.0)).round(2)} MB"
      end
    end

    private def capture_wayland_image : PendingImage?
      types_out = run_capture_text("wl-paste", ["--list-types"])
      return nil unless types_out
      types = types_out.lines.map(&.strip)
      mime = PREFERRED_MIMES.find { |m| types.includes?(m) }
      return nil unless mime

      bytes = run_capture_bytes("wl-paste", ["--type", mime])
      return nil unless bytes && !bytes.empty? && bytes.size <= Nightmare::Config::MAX_IMAGE_BYTES
      b64, final_mime, final_size = Mantle::Support::Image.encode_base64(bytes, mime)
      PendingImage.new(
        label: "clipboard",
        mime: final_mime,
        size_bytes: final_size,
        base64: b64
      )
    end

    private def capture_x11_image : PendingImage?
      targets_out = run_capture_text("xclip", ["-selection", "clipboard", "-t", "TARGETS", "-o"])
      return nil unless targets_out
      targets = targets_out.lines.map(&.strip)
      mime = PREFERRED_MIMES.find { |m| targets.includes?(m) }
      return nil unless mime

      bytes = run_capture_bytes("xclip", ["-selection", "clipboard", "-t", mime, "-o"])
      return nil unless bytes && !bytes.empty? && bytes.size <= Nightmare::Config::MAX_IMAGE_BYTES
      b64, final_mime, final_size = Mantle::Support::Image.encode_base64(bytes, mime)
      PendingImage.new(
        label: "clipboard",
        mime: final_mime,
        size_bytes: final_size,
        base64: b64
      )
    end

    private def run_capture_text(cmd : String, args : Array(String)) : String?
      bytes = run_capture_bytes(cmd, args)
      return nil unless bytes
      String.new(bytes)
    rescue
      nil
    end

    private def run_capture_bytes(cmd : String, args : Array(String)) : Bytes?
      out_io = IO::Memory.new
      err_io = IO::Memory.new
      status = Process.run(cmd, args, output: out_io, error: err_io)
      return nil unless status.success?
      out_io.to_slice
    rescue
      nil
    end
  end
end
