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
    METACHARACTERS = [
      ';', '&', '|', '`', '$', '>', '<', '\n', '\r', '(', ')', '{', '}',
      '\\', '*', '?', '[', ']', '~', '#', '!', '\0', '\e'
    ]

    # Subcommand-driven tools where argv[1] is a discrete operation mode
    SUBCOMMAND_BINARIES = Set{
      "git", "cargo", "npm", "pnpm", "yarn", "crystal", "docker", "podman", "kubectl", "helm"
    }

    # High-risk flags that unconditionally force interactive confirmation
    DENYLISTED_EXACT_FLAGS = Set{
      "-c", "-e", "-E", "-C",
      "--config", "--upload-pack", "--receive-pack",
      "-exec", "-execdir", "-ok", "-okdir"
    }

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
        elsif (ch == ' ' || ch == '\t') && !in_single_quote && !in_double_quote
          if has_token
            tokens << current.to_s
            current = String::Builder.new
            has_token = false
          end
        elsif (ch == '\r' || ch == '\n' || ch.whitespace? || ch.control?) && !in_single_quote && !in_double_quote
          raise ArgumentError.new("Invalid command syntax: control or non-standard whitespace character")
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
    # Checks: -c, -e, -E, -C, --exec*, --eval*, --config*, --upload-pack*, --receive-pack*,
    # -exec*, -ok*, attached options (-Cdir, -cCMD), bundled flags (-ec, -ne),
    # and any token containing '=' before the first non-flag argument or env assignments.
    def self.has_denylisted_flags?(argv : Array(String)) : Bool
      return false if argv.empty?

      binary = File.basename(argv[0])
      is_env_wrapper = (binary == "env")
      seen_target_binary = false

      argv.each_with_index do |token, idx|
        if idx == 0
          return true if token.includes?('=')
          next
        end

        if is_env_wrapper && !seen_target_binary
          if token.includes?('=')
            return true
          elsif !token.starts_with?('-')
            seen_target_binary = true
          end
        elsif !seen_target_binary && token.includes?('=')
          return true
        end

        if !token.starts_with?('-')
          seen_target_binary = true
          next
        end

        # Check exact denylisted flags
        return true if DENYLISTED_EXACT_FLAGS.includes?(token)

        # Check long flag prefixes
        if token.starts_with?("--exec") || token.starts_with?("--eval") ||
           token.starts_with?("--config=") || token.starts_with?("--upload-pack=") ||
           token.starts_with?("--receive-pack=") || token.starts_with?("--checkpoint-action=") ||
           token.starts_with?("--to-command=")
          return true
        end

        # Check short options with attached values (-c..., -C..., -e..., -E...)
        if token.starts_with?("-c") || token.starts_with?("-C") || token.starts_with?("-e") || token.starts_with?("-E")
          return true
        end

        # Check bundled short flags (e.g. -xvzc where 'c' or 'e' or 'E' or 'C' is bundled in a flag string like -ne, -ec)
        if token.starts_with?('-') && !token.starts_with?("--")
          chars = token[1..].chars
          if chars.includes?('c') || chars.includes?('e') || chars.includes?('E') || chars.includes?('C')
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

      # 1. Exact binary prefix (e.g. "sleep", "ls", "python3")
      return true if @session_prefix.includes?(binary) || @persistent_prefix.includes?(binary)

      # 2. Subcommand prefix (e.g. "git status", "crystal spec")
      if SUBCOMMAND_BINARIES.includes?(binary) && argv.size > 1 && !argv[1].starts_with?('-')
        subcommand_key = "#{binary} #{argv[1]}"
        return true if @session_prefix.includes?(subcommand_key) || @persistent_prefix.includes?(subcommand_key)
      end

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

      if SUBCOMMAND_BINARIES.includes?(binary) && argv.size > 1 && !argv[1].starts_with?('-')
        @session_prefix.add("#{binary} #{argv[1]}")
      elsif argv.size == 1
        @session_prefix.add(binary)
      else
        allow_session_exact(argv)
      end
    end

    # Persists a prefix or exact command to $XDG_CONFIG_HOME/.../allow
    def allow_persist_prefix(argv : Array(String)) : Nil
      return if argv.empty?
      binary = File.basename(argv[0])

      if SUBCOMMAND_BINARIES.includes?(binary) && argv.size > 1 && !argv[1].starts_with?('-')
        @persistent_prefix.add("#{binary} #{argv[1]}")
        save_persistent
      elsif argv.size == 1
        @persistent_prefix.add(binary)
        save_persistent
      else
        allow_persist_exact(argv)
      end
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

      dir = File.dirname(path)
      Dir.mkdir_p(dir)

      tmp_path = "#{path}.tmp.#{Process.pid}"
      begin
        File.open(tmp_path, "w") do |f|
          @persistent_prefix.each do |p|
            f.puts "prefix:#{p}"
          end
          @persistent_exact.each do |e|
            f.puts e
          end
          @persistent_patterns.each do |re|
            f.puts re.source
          end
        end
        File.rename(tmp_path, path)
      ensure
        File.delete(tmp_path) rescue nil if File.exists?(tmp_path)
      end
    end
  end
end
