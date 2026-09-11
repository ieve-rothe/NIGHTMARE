# nightmare/tools/registry.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "mantle"
require "./guard"
require "./allowlist"
require "./read_only"
require "./mutation"
require "./shell"
require "./delegation"

module Nightmare::Tools
  class Registry
    getter guard : Guard
    getter allowlist : Allowlist
    getter read_only : ReadOnly
    getter mutation : Mutation
    getter shell : Shell
    getter delegation : Delegation

    def initialize(
      @guard : Guard,
      client : Mantle::Clients::Client,
      @allowlist : Allowlist = Allowlist.new,
      diff_approval : Proc(String, String, Bool)? = nil,
      shell_approval : Proc(String, Array(String), Bool, Tuple(ApprovalOutcome, String?))? = nil
    )
      @read_only = ReadOnly.new(@guard)
      @mutation = Mutation.new(@guard, diff_approval)
      @shell = Shell.new(@guard, @allowlist, shell_approval)
      @delegation = Delegation.new(client)
    end

    def set_active_side_effects(effects : Array(String)?) : Nil
      @mutation.active_side_effects = effects
      @shell.active_side_effects = effects
    end

    # Builds the array of Mantle::Tools::Tool definitions with schema and execution handlers
    def build_tools : Array(Mantle::Tools::Tool)
      [
        build_list_files_tool,
        build_search_tool,
        build_read_file_tool,
        build_file_info_tool,
        build_write_file_tool,
        build_replace_in_file_tool,
        build_append_to_file_tool,
        build_run_command_tool,
        build_ask_model_tool,
      ]
    end

    private def build_list_files_tool : Mantle::Tools::Tool
      props = {
        "path" => Mantle::Tools::PropertyDefinition.new("string", "Directory path relative to workspace root (defaults to .)"),
        "glob" => Mantle::Tools::PropertyDefinition.new("string", "Glob pattern to filter filenames (e.g. **/*.cr)"),
      }
      schema = Mantle::Tools::ParametersSchema.new(props)
      func = Mantle::Tools::FunctionDefinition.new("list_files", "Lists files in workspace with glob filtering, excluding git and sensitive files.", schema)

      Mantle::Tools::Tool.new(func) do |args|
        path = args["path"]?.try(&.as_s?)
        glob = args["glob"]?.try(&.as_s?)
        @read_only.list_files(path, glob)
      end
    end

    private def build_search_tool : Mantle::Tools::Tool
      props = {
        "pattern" => Mantle::Tools::PropertyDefinition.new("string", "Regex pattern to search for in files"),
        "path"    => Mantle::Tools::PropertyDefinition.new("string", "Directory path relative to workspace root"),
        "glob"    => Mantle::Tools::PropertyDefinition.new("string", "Glob pattern to restrict search files"),
      }
      schema = Mantle::Tools::ParametersSchema.new(props, ["pattern"])
      func = Mantle::Tools::FunctionDefinition.new("search", "Searches file contents across workspace for a regex pattern.", schema)

      Mantle::Tools::Tool.new(func) do |args|
        pattern = args["pattern"]?.try(&.as_s) || ""
        path = args["path"]?.try(&.as_s?)
        glob = args["glob"]?.try(&.as_s?)
        @read_only.search(pattern, path, glob)
      end
    end

    private def build_read_file_tool : Mantle::Tools::Tool
      props = {
        "path"   => Mantle::Tools::PropertyDefinition.new("string", "Path to file to read"),
        "offset" => Mantle::Tools::PropertyDefinition.new("integer", "1-based line number to begin reading from"),
        "limit"  => Mantle::Tools::PropertyDefinition.new("integer", "Maximum number of lines to read"),
      }
      schema = Mantle::Tools::ParametersSchema.new(props, ["path"])
      func = Mantle::Tools::FunctionDefinition.new("read_file", "Reads file contents safely with optional line offset and limit.", schema)

      Mantle::Tools::Tool.new(func) do |args|
        path = args["path"]?.try(&.as_s) || ""
        offset = args["offset"]?.try(&.as_i?)
        limit = args["limit"]?.try(&.as_i?)
        @read_only.read_file(path, offset, limit)
      end
    end

    private def build_file_info_tool : Mantle::Tools::Tool
      props = {
        "path" => Mantle::Tools::PropertyDefinition.new("string", "Path to file or directory"),
      }
      schema = Mantle::Tools::ParametersSchema.new(props, ["path"])
      func = Mantle::Tools::FunctionDefinition.new("file_info", "Returns metadata for a file or directory in the workspace.", schema)

      Mantle::Tools::Tool.new(func) do |args|
        path = args["path"]?.try(&.as_s) || ""
        @read_only.file_info(path)
      end
    end

    private def build_write_file_tool : Mantle::Tools::Tool
      props = {
        "path"    => Mantle::Tools::PropertyDefinition.new("string", "Path to write to"),
        "content" => Mantle::Tools::PropertyDefinition.new("string", "Content to write to file"),
      }
      schema = Mantle::Tools::ParametersSchema.new(props, ["path", "content"])
      func = Mantle::Tools::FunctionDefinition.new("write_file", "Creates new file or overwrites existing file with unified diff approval.", schema)

      Mantle::Tools::Tool.new(func) do |args|
        path = args["path"]?.try(&.as_s) || ""
        content = args["content"]?.try(&.as_s) || ""
        @mutation.write_file(path, content)
      end
    end

    private def build_replace_in_file_tool : Mantle::Tools::Tool
      props = {
        "path"        => Mantle::Tools::PropertyDefinition.new("string", "Path to file to edit"),
        "target"      => Mantle::Tools::PropertyDefinition.new("string", "Exact unique substring to replace"),
        "replacement" => Mantle::Tools::PropertyDefinition.new("string", "Replacement content"),
      }
      schema = Mantle::Tools::ParametersSchema.new(props, ["path", "target", "replacement"])
      func = Mantle::Tools::FunctionDefinition.new("replace_in_file", "Replaces unique substring in existing file with diff approval.", schema)

      Mantle::Tools::Tool.new(func) do |args|
        path = args["path"]?.try(&.as_s) || ""
        target = args["target"]?.try(&.as_s) || ""
        replacement = args["replacement"]?.try(&.as_s) || ""
        @mutation.replace_in_file(path, target, replacement)
      end
    end

    private def build_append_to_file_tool : Mantle::Tools::Tool
      props = {
        "path"    => Mantle::Tools::PropertyDefinition.new("string", "Path to file"),
        "content" => Mantle::Tools::PropertyDefinition.new("string", "Content to append"),
      }
      schema = Mantle::Tools::ParametersSchema.new(props, ["path", "content"])
      func = Mantle::Tools::FunctionDefinition.new("append_to_file", "Appends content to file with diff approval if existing.", schema)

      Mantle::Tools::Tool.new(func) do |args|
        path = args["path"]?.try(&.as_s) || ""
        content = args["content"]?.try(&.as_s) || ""
        @mutation.append_to_file(path, content)
      end
    end

    private def build_run_command_tool : Mantle::Tools::Tool
      props = {
        "command"         => Mantle::Tools::PropertyDefinition.new("string", "Command to execute"),
        "timeout_seconds" => Mantle::Tools::PropertyDefinition.new("integer", "Timeout cap in seconds"),
      }
      schema = Mantle::Tools::ParametersSchema.new(props, ["command"])
      func = Mantle::Tools::FunctionDefinition.new("run_command", "Executes command via argv supervisor in isolated process group.", schema)

      Mantle::Tools::Tool.new(func) do |args|
        cmd = args["command"]?.try(&.as_s) || ""
        timeout = args["timeout_seconds"]?.try(&.as_i?)
        @shell.run_command(cmd, timeout)
      end
    end

    private def build_ask_model_tool : Mantle::Tools::Tool
      props = {
        "prompt" => Mantle::Tools::PropertyDefinition.new("string", "Sub-prompt to delegate to isolated model"),
      }
      schema = Mantle::Tools::ParametersSchema.new(props, ["prompt"])
      func = Mantle::Tools::FunctionDefinition.new("ask_model", "Performs stateless one-shot inference delegation without history pollution.", schema)

      Mantle::Tools::Tool.new(func) do |args|
        prompt = args["prompt"]?.try(&.as_s) || ""
        @delegation.ask_model(prompt)
      end
    end
  end
end
