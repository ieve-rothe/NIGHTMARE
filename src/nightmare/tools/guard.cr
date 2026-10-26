# nightmare/tools/guard.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "path"
require "mantle"
require "../exceptions"
require "../config"
require "../workspace/environment"

module Nightmare::Tools
  class Guard
    getter env : Workspace::Environment
    getter files_targeted : Array(String)? = nil

    def files_targeted=(val : Array(String)?)
      @files_targeted = val
      @sandbox.files_targeted = val
    end

    getter sandbox : Mantle::Tools::FileSystemSandbox

    # Sensitive read glob patterns per ARCHITECTURE §4.1
    SENSITIVE_READ_PATTERNS = Mantle::Tools::FileSystemSandbox::DEFAULT_SENSITIVE_PATTERNS

    def initialize(@env : Workspace::Environment, @files_targeted : Array(String)? = nil)
      allowed = [@env.root] + @env.readable_directories
      @sandbox = Mantle::Tools::FileSystemSandbox.new(
        working_directory: @env.root,
        allowed_paths: allowed,
        files_targeted: @files_targeted,
        sensitive_patterns: SENSITIVE_READ_PATTERNS.dup
      )
    end

    def root : String
      @env.root
    end

    # Resolves a path for reading.
    # Enforces containment within @root or configured readable_directories and guards against sensitive patterns.
    # Raises SecurityError on traversal or sensitive file access.
    def resolve_read(path : String) : String
      contained = @env.resolve_contained_path(path)
      if sensitive_path?(path) || sensitive_path?(contained) || protected_path?(path) || protected_path?(contained)
        raise SecurityError.new("Access denied: reading sensitive file or pattern is prohibited: #{path}")
      end

      full = @env.sanitize_read_path(path)
      rel = if @env.inside_root?(full)
        Path.new(full).relative_to(@env.root).to_s
      else
        matching_dir = @env.readable_directories.find do |d|
          d_prefix = d.ends_with?('/') ? d : "#{d}/"
          full == d || full.starts_with?(d_prefix)
        end
        if matching_dir
          Path.new(full).relative_to(matching_dir).to_s
        else
          full
        end
      end

      if sensitive_path?(rel) || sensitive_path?(File.basename(full)) || protected_path?(rel)
        raise SecurityError.new("Access denied: reading sensitive file or pattern is prohibited: #{path}")
      end

      full
    end

    # Checks if a relative or absolute path matches sensitive read patterns.
    def sensitive_read?(rel_path : String) : Bool
      sensitive_path?(rel_path)
    end

    # Checks if any path segment or basename matches sensitive patterns (.ssh, .gnupg, credentials, etc.)
    def sensitive_path?(path : String) : Bool
      return true if @sandbox.sensitive_path?(path)
      parts = path.split('/')
      parts.any? { |p| p == ".ssh" || p == ".gnupg" || @sandbox.sensitive_path?(p) }
    end

    # Resolves a path for writing / mutation.
    # Enforces non-sensitive and non-protected boundaries. If outside @root, mutation is elevated
    # to user approval in Mutation tools.
    # Raises SecurityError on protected path, sensitive patterns, readonly directory, or target mismatch.
    def resolve_write(path : String) : String
      contained = @env.resolve_contained_path(path)

      if protected_path?(path) || protected_path?(contained) || protected_path?(File.basename(contained))
        raise SecurityError.new("[Refused: #{path} is a protected path]")
      end

      if sensitive_path?(path) || sensitive_path?(contained) || sensitive_path?(File.basename(contained))
        raise SecurityError.new("[Refused: #{path} is a sensitive path]")
      end

      if @env.readonly_directory?(contained)
        raise SecurityError.new("Path traversal violation: target \"#{path}\" resolves to \"#{contained}\" within read-only directory")
      end

      full = contained
      rel = if @env.inside_root?(full)
        Path.new(full).relative_to(@env.root).to_s
      else
        matching_dir = @env.writable_directories.find do |d|
          d_prefix = d.ends_with?('/') ? d : "#{d}/"
          full == d || full.starts_with?(d_prefix)
        end
        if matching_dir
          Path.new(full).relative_to(matching_dir).to_s
        else
          full
        end
      end

      if targets = @files_targeted
        unless targets.empty? || @sandbox.path_matches_targeted?(full)
          clean_rel = normalize_rel(rel)
          raise SecurityError.new("Policy error: Path '#{clean_rel}' is not within allowed files_targeted: #{targets.join(", ")}. Propose adding it to proposed_targets if required.")
        end
      end

      full
    end

    # Checks if a relative path is in the protected path list:
    # .git, .git/**, .nightmare/**, .nightmare* (any sibling)
    def protected_path?(rel_path : String) : Bool
      @sandbox.protected_path?(rel_path)
    end

    private def normalize_rel(rel_path : String) : String
      rel = rel_path
      while rel.starts_with?("./")
        rel = rel[2..]
      end
      rel
    end

    # Caps tool output string at max_bytes.
    def self.cap_output(output : String, max_bytes : Int32 = Config::TOOL_OUTPUT_MAX_BYTES) : String
      return output if output.bytesize <= max_bytes

      # Find byte offset within max_bytes without splitting UTF-8 codepoints
      sliced = output.byte_slice(0, max_bytes)
      "#{sliced}\n[... truncated at #{max_bytes} bytes; call read_file with offset=X limit=Y for more]"
    end
  end
end
