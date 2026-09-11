# nightmare/tools/allowlist.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "file_utils"
require "../exceptions"

module Nightmare::Tools
  class Allowlist
    getter allowlist_path : String?
    getter session_exact : Set(String)
    getter session_prefix : Set(String)
    getter persistent_exact : Set(String)
    getter persistent_prefix : Set(String)
    getter persistent_patterns : Array(Regex)

    # Characters that bar auto-approval and force interactive confirmation (R3 / §4.2)
    METACHARACTERS = [';', '&', '|', '`', '$', '>', '<', '\n', '(', ')', '{', '}', '\\', '*']

    def initialize(@allowlist_path : String? = nil)
      @session_exact = Set(String).new
      @session_prefix = Set(String).new
      @persistent_exact = Set(String).new
      @persistent_prefix = Set(String).new
      @persistent_patterns = [] of Regex

      load_persistent
    end

    # POSIX-compliant shell argument tokenizer
    def self.tokenize(command : String) : Array(String)
      tokens = [] of String
      current = String::Builder.new
      in_single_quote = false
      in_double_quote = false
      escaped = false
      has_token = false

      command.each_char do |ch|
        if escaped
          current << ch
          escaped = false
          has_token = true
        elsif ch == '\\' && !in_single_quote
          escaped = true
          has_token = true
        elsif ch == '\'' && !in_double_quote
          in_single_quote = !in_single_quote
          has_token = true
        elsif ch == '"' && !in_single_quote
          in_double_quote = !in_double_quote
          has_token = true
        elsif ch.whitespace? && !in_single_quote && !in_double_quote
          if has_token
            tokens << current.to_s
            current = String::Builder.new
            has_token = false
          end
        else
          current << ch
          has_token = true
        end
      end

      if escaped || in_single_quote || in_double_quote
        raise ArgumentError.new("Invalid command syntax: unbalanced quotes or trailing backslash")
      end

      tokens << current.to_s if has_token
      tokens
    end

    # Checks if command string contains any banned shell metacharacters
    def self.contains_metacharacters?(command : String) : Bool
      METACHARACTERS.any? { |ch| command.includes?(ch) }
    end

    # Flag denylist: forces modal confirmation regardless of allowlist state (§4.2)
    # Checks: -c, -e, --exec*, --eval*, -C, --config, --upload-pack, --receive-pack,
    # and any token containing '=' before the first non-flag argument (e.g. ENV=var).
    def self.has_denylisted_flags?(argv : Array(String)) : Bool
      return false if argv.empty?

      seen_non_flag = false

      argv.each_with_index do |token, idx|
        # Any token with '=' before first command binary or as first arg is an env injection
        if !seen_non_flag && token.includes?('=')
          return true
        end

        # Basename of the binary
        if idx == 0
          seen_non_flag = true unless token.starts_with?('-')
          next
        end

        seen_non_flag = true unless token.starts_with?('-')

        # Flag checks
        case token
        when "-c", "-e", "-C", "--config", "--upload-pack", "--receive-pack"
          return true
        else
          if token.starts_with?("--exec") || token.starts_with?("--eval")
            return true
          end
          if token.starts_with?("-c=") || token.starts_with?("-C=") || token.starts_with?("--config=")
            return true
          end
        end
      end

      false
    end

    # Checks if argv matches session or persisted allowlists
    def matches?(argv : Array(String)) : Bool
      return false if argv.empty?

      exact_key = argv.join(" ")
      return true if @session_exact.includes?(exact_key) || @persistent_exact.includes?(exact_key)
      return true if @persistent_patterns.any? { |re| exact_key =~ re }

      binary = File.basename(argv[0])
      prefix_key = if argv.size > 1 && !argv[1].starts_with?('-')
        "#{binary} #{argv[1]}"
      else
        binary
      end

      return true if @session_prefix.includes?(prefix_key) || @persistent_prefix.includes?(prefix_key)
      return true if @session_prefix.includes?(binary) || @persistent_prefix.includes?(binary)

      false
    end

    # Evaluates whether a command is eligible for autonomous execution
    def auto_approvable?(command : String, argv : Array(String)) : Bool
      return false if self.class.contains_metacharacters?(command)
      return false if self.class.has_denylisted_flags?(argv)
      matches?(argv)
    end

    # Records an exact command approval for the active session
    def allow_session_exact(argv : Array(String)) : Nil
      @session_exact.add(argv.join(" "))
    end

    # Persists an exact command to $XDG_CONFIG_HOME/.../allow
    def allow_persist_exact(argv : Array(String)) : Nil
      return if argv.empty?
      @persistent_exact.add(argv.join(" "))
      save_persistent
    end

    # Records a prefix approval (argv[0] + argv[1]) for the active session
    def allow_session_prefix(argv : Array(String)) : Nil
      return if argv.empty?
      binary = File.basename(argv[0])
      prefix = if argv.size > 1 && !argv[1].starts_with?('-')
        "#{binary} #{argv[1]}"
      else
        binary
      end
      @session_prefix.add(prefix)
    end

    # Persists a prefix or exact command to $XDG_CONFIG_HOME/.../allow
    def allow_persist_prefix(argv : Array(String)) : Nil
      return if argv.empty?
      binary = File.basename(argv[0])
      prefix = if argv.size > 1 && !argv[1].starts_with?('-')
        "#{binary} #{argv[1]}"
      else
        binary
      end
      @persistent_prefix.add(prefix)
      save_persistent
    end

    private def load_persistent : Nil
      path = @allowlist_path
      return unless path && File.exists?(path)

      File.read_lines(path).each do |line|
        trimmed = line.strip
        next if trimmed.empty? || trimmed.starts_with?('#')
        if trimmed.starts_with?("prefix:")
          @persistent_prefix.add(trimmed[7..].strip)
        elsif trimmed.starts_with?('^') || trimmed.ends_with?('$') || trimmed.includes?(".*")
          begin
            @persistent_patterns << Regex.new(trimmed)
          rescue
            @persistent_exact.add(trimmed)
          end
        else
          @persistent_exact.add(trimmed)
        end
      end
    end

    private def save_persistent : Nil
      path = @allowlist_path
      return unless path

      Dir.mkdir_p(File.dirname(path))
      File.open(path, "w") do |f|
        @persistent_prefix.each do |p|
          f.puts "prefix:#{p}"
        end
        @persistent_exact.each do |e|
          f.puts e
        end
      end
    end
  end
end
