# nightmare/tools/registry.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "mantle"
require "./guard"
require "./allowlist"
require "./read_only"
require "./mutation"
require "./shell"
require "./middleware"
require "../harness/subagent_runner"
require "../keys"

module Nightmare::Tools
  class Registry
    getter guard : Guard
    getter allowlist : Allowlist
    getter read_only : ReadOnly
    getter mutation : Mutation
    getter shell : Shell
    property subagent_runner : Harness::SubagentRunner?
    property middlewares : Array(ToolMiddleware::Base) = [] of ToolMiddleware::Base

    def initialize(
      @guard : Guard,
      client : Mantle::Clients::Client,
      @allowlist : Allowlist = Allowlist.new,
      diff_approval : Proc(String, String, Bool)? = nil,
      shell_approval : Proc(String, Array(String), Bool, Int32, Tuple(ApprovalOutcome, String?))? = nil,
      pinned_files : Context::PinnedFiles? = nil,
      default_command_timeout : Int32 = Config::SHELL_COMMAND_TIMEOUT_SECONDS,
      max_command_timeout : Int32 = Config::SHELL_COMMAND_MAX_TIMEOUT_SECONDS,
      tool_output_max_bytes : Int32 = Config::TOOL_OUTPUT_MAX_BYTES,
      @subagent_runner : Harness::SubagentRunner? = nil
    )
      @read_only = ReadOnly.new(@guard, pinned_files)
      @mutation = Mutation.new(@guard, diff_approval)
      @shell = Shell.new(
        guard: @guard,
        allowlist: @allowlist,
        approval_handler: shell_approval,
        default_timeout_seconds: default_command_timeout,
        max_timeout_seconds: max_command_timeout,
        tool_output_max_bytes: tool_output_max_bytes
      )
    end

    def set_active_side_effects(effects : Array(String)?) : Nil
      @mutation.active_side_effects = effects
      @shell.active_side_effects = effects
    end

    # Builds the array of Mantle::Tools::Tool definitions with schema and execution handlers
    def build_tools : Array(Mantle::Tools::Tool)
      tools = [
        build_list_files_tool,
        build_search_tool,
        build_read_file_tool,
        build_file_info_tool,
        build_write_file_tool,
        build_replace_in_file_tool,
        build_append_to_file_tool,
        build_run_command_tool,
        build_spawn_subagent_tool,
        build_web_search_tool,
      ]
      ToolMiddleware.wrap_all(tools, @middlewares)
    end

    # Builds toolset for subagents: omits recursive delegation tools
    def build_subagent_tools : Array(Mantle::Tools::Tool)
      tools = [
        build_list_files_tool,
        build_search_tool,
        build_read_file_tool,
        build_file_info_tool,
        build_write_file_tool,
        build_replace_in_file_tool,
        build_append_to_file_tool,
        build_run_command_tool,
        build_web_search_tool,
      ]
      ToolMiddleware.wrap_all(tools, @middlewares)
    end

    private def build_list_files_tool : Mantle::Tools::Tool
      props = {
        "path" => Mantle::Tools::PropertyDefinition.new("string", "Directory path relative to workspace root (defaults to .)"),
        "glob" => Mantle::Tools::PropertyDefinition.new("string", "Glob pattern to filter filenames (e.g. **/*.cr)"),
      }
      schema = Mantle::Tools::ParametersSchema.new(props)
      func = Mantle::Tools::FunctionDefinition.new("list_files", "Lists files in workspace with glob filtering, excluding git and sensitive files.", schema)

      Mantle::Tools::Tool.new(func) do |args|
        path = args["path"]?.try(&.as_s?) || args["directory"]?.try(&.as_s?)
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
        pattern = args["pattern"]?.try(&.as_s?) || args["query"]?.try(&.as_s?) || ""
        path = args["path"]?.try(&.as_s?) || args["directory"]?.try(&.as_s?)
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
      func = Mantle::Tools::FunctionDefinition.new(
        "read_file",
        "Reads file contents safely with optional line offset and limit. Returns file contents with '<line> | ' prefixes for line referencing. Use these line numbers with replace_in_file's 'start_line' and 'end_line'.",
        schema
      )

      Mantle::Tools::Tool.new(func) do |args|
        path = args["path"]?.try(&.as_s?) || args["filepath"]?.try(&.as_s?) || ""
        raw_offset = args["offset"]?
        offset = raw_offset.try(&.as_i?) || raw_offset.try(&.as_s?.try(&.to_i?))
        raw_limit = args["limit"]?
        limit = raw_limit.try(&.as_i?) || raw_limit.try(&.as_s?.try(&.to_i?))
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
        "target"      => Mantle::Tools::PropertyDefinition.new("string", "Exact unique substring to replace. When provided with start_line, validates content and derives end_line if end_line is omitted."),
        "replacement" => Mantle::Tools::PropertyDefinition.new("string", "Replacement content"),
        "start_line"  => Mantle::Tools::PropertyDefinition.new("integer", "Optional 1-based start line number for line-anchored replacement"),
        "end_line"    => Mantle::Tools::PropertyDefinition.new("integer", "Optional 1-based end line number. If omitted when target is provided, derived from target length; if omitted without target, defaults to start_line."),
      }
      schema = Mantle::Tools::ParametersSchema.new(props, ["path", "replacement"])
      func = Mantle::Tools::FunctionDefinition.new(
        "replace_in_file",
        "Replaces unique substring or line-anchored range (start_line..end_line) in existing file with diff approval.",
        schema
      )

      Mantle::Tools::Tool.new(func) do |args|
        path = args["path"]?.try(&.as_s) || ""
        target = args["target"]?.try(&.as_s) || ""
        replacement = args["replacement"]?.try(&.as_s) || ""
        raw_start = args["start_line"]?
        start_line = raw_start.try(&.as_i?) || raw_start.try(&.as_s?.try(&.to_i?))
        raw_end = args["end_line"]?
        end_line = raw_end.try(&.as_i?) || raw_end.try(&.as_s?.try(&.to_i?))
        @mutation.replace_in_file(path, target, replacement, start_line, end_line)
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
        raw_to = args["timeout"]? || args["timeout_seconds"]?
        timeout = raw_to.try(&.as_i?) || raw_to.try(&.as_s?.try(&.to_i?))
        @shell.run_command(cmd, timeout)
      end
    end

    private def build_spawn_subagent_tool : Mantle::Tools::Tool
      props = {
        "task"           => Mantle::Tools::PropertyDefinition.new("string", "The concrete task or deliverable for the subagent to execute"),
        "files_targeted" => Mantle::Tools::PropertyDefinition.new("string", "Optional comma-separated list of target files or globs permitted for mutation"),
      }
      schema = Mantle::Tools::ParametersSchema.new(props, ["task"])
      func = Mantle::Tools::FunctionDefinition.new(
        "spawn_subagent",
        "Spawns an autonomous subagent with its own tool loop to execute a concrete subtask without polluting parent history.",
        schema
      )

      Mantle::Tools::Tool.new(func) do |args|
        task = args["task"]?.try(&.as_s) || args["prompt"]?.try(&.as_s) || args["query"]?.try(&.as_s) || ""
        files_targeted = [] of String
        if raw_targets = args["files_targeted"]?
          if raw_targets.as_a?
            files_targeted = raw_targets.as_a.compact_map(&.as_s?)
          elsif s = raw_targets.as_s?
            files_targeted = s.split(',').map(&.strip).reject(&.empty?)
          end
        end

        if runner = @subagent_runner
          runner.run_subagent(task, files_targeted)
        else
          "[Subagent error: No subagent runner configured]"
        end
      end
    end

    private def build_web_search_tool : Mantle::Tools::Tool
      Mantle::Tools::Builtin::WebSearch.create(->{ Keys.get?("tavily", @guard.env) })
    end
  end
end
