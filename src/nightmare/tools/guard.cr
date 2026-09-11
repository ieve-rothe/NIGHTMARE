# nightmare/tools/guard.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "path"
require "../exceptions"
require "../config"
require "../workspace/environment"

module Nightmare::Tools
  class Guard
    getter env : Workspace::Environment

    # Sensitive read glob patterns per ARCHITECTURE_R3 §4.1
    SENSITIVE_READ_PATTERNS = [
      ".env*",
      "*.pem",
      "id_rsa*",
      "*secret*",
      "*credential*",
      ".git",
      ".git/*",
      ".git/**"
    ]

    def initialize(@env : Workspace::Environment)
    end

    def root : String
      @env.root
    end

    # Resolves a path for reading.
    # Enforces containment within @root and guards against sensitive patterns.
    # Raises SecurityError on traversal or sensitive file access.
    def resolve_read(path : String) : String
      full = @env.sanitize_path(path)
      rel = Path.new(full).relative_to(@env.root).to_s

      if sensitive_read?(rel)
        raise SecurityError.new("Access denied: reading sensitive file or pattern is prohibited: #{path}")
      end

      full
    end

    # Checks if a relative path matches sensitive read patterns.
    def sensitive_read?(rel_path : String) : Bool
      clean_rel = normalize_rel(rel_path)
      basename = File.basename(clean_rel)

      SENSITIVE_READ_PATTERNS.any? do |pattern|
        File.match?(pattern, clean_rel) || File.match?(pattern, basename)
      end
    end

    # Resolves a path for writing / mutation.
    # Enforces containment within @root and unconditionally blocks protected paths.
    # Raises SecurityError on traversal.
    def resolve_write(path : String) : String
      full = @env.sanitize_path(path)
      rel = Path.new(full).relative_to(@env.root).to_s

      if protected_path?(rel)
        raise SecurityError.new("[Refused: #{path} is a protected path]")
      end

      full
    end

    # Checks if a relative path is in the protected path list:
    # .git, .git/**, .nightmare/**, .nightmare* (any sibling)
    def protected_path?(rel_path : String) : Bool
      clean_rel = normalize_rel(rel_path)
      return true if clean_rel == ".git" || clean_rel.starts_with?(".git/")
      return true if clean_rel == ".nightmare" || clean_rel.starts_with?(".nightmare/")
      return true if clean_rel.starts_with?(".nightmare")

      # Also check each path segment in nested paths (e.g. sub/.git or sub/.nightmare)
      parts = clean_rel.split('/')
      parts.any? { |p| p == ".git" || p.starts_with?(".nightmare") }
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
