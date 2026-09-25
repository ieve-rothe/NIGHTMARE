require "option_parser"
require "mantle"
require "salamander"
require "./nightmare/exceptions"
require "./nightmare/config"
require "./nightmare/settings"
require "./nightmare/keys"
require "./nightmare/workspace/manifest"
require "./nightmare/workspace/environment"
require "./nightmare/system_prompt/resolver"
require "./nightmare/harness/types"
require "./nightmare/harness/loop_detector"
require "./nightmare/harness/retrier"
require "./nightmare/harness/tool_loop"
require "./nightmare/harness/step_runner"
require "./nightmare/tools/guard"
require "./nightmare/tools/diff"
require "./nightmare/tools/allowlist"
require "./nightmare/tools/read_only"
require "./nightmare/tools/mutation"
require "./nightmare/tools/shell"
require "./nightmare/tools/registry"
require "./nightmare/context/turn"
require "./nightmare/context/token_calibrator"
require "./nightmare/context/pinned_files"
require "./nightmare/context/shedder"
require "./nightmare/context/sliding_store"
require "./nightmare/transcript"
require "./nightmare/plan"
require "./nightmare/harness/subagent_runner"
require "./nightmare/repl"

module Nightmare
  VERSION = "0.3.1"

  module CLI
    struct Options
      property system_prompt_path : String? = nil
      property no_log : Bool = false
      property model : String? = nil
      property markdown : Bool? = nil
      property target_dir : String = ""
      property show_help : Bool = false
      property show_version : Bool = false
      property error_message : String? = nil
    end

    class Parser
      def self.parse(args : Array(String) = ARGV) : Options
        options = Options.new

        parser = OptionParser.new do |opts|
          opts.banner = "Usage: nightmare [options] [workspace_path]"

          opts.on("-s PATH", "--system=PATH", "Path to custom system prompt file (overrides all defaults)") do |path|
            options.system_prompt_path = path
          end

          opts.on("--no-logs", "--no-log", "Disable LLM interaction logging and run in zero-footprint ghost mode") do
            options.no_log = true
          end

          opts.on("-m MODEL", "--model=MODEL", "Select model provider or alias") do |model|
            options.model = model
          end

          opts.on("--markdown", "Enable ANSI markdown formatting in terminal (default)") do
            options.markdown = true
          end

          opts.on("--no-markdown", "Disable ANSI markdown formatting in terminal") do
            options.markdown = false
          end

          opts.on("-v", "--version", "Show NIGHTMARE version") do
            options.show_version = true
          end

          opts.on("-h", "--help", "Show help and command-line usage information") do
            options.show_help = true
          end

          opts.unknown_args do |remaining|
            if target = remaining.first?
              options.target_dir = target
            end
          end
        end

        begin
          parser.parse(args)
        rescue ex : OptionParser::InvalidOption | OptionParser::MissingOption
          options.error_message = ex.message
        end

        options
      end

      def self.help_text : String
        String.build do |io|
          opts = OptionParser.new do |p|
            p.banner = "NIGHTMARE - Developer REPL\nUsage: nightmare [options] [workspace_path]"
            p.on("-s PATH", "--system=PATH", "Path to custom system prompt file") { }
            p.on("--no-logs", "--no-log", "Disable logging and run in zero-footprint ghost mode") { }
            p.on("-m MODEL", "--model=MODEL", "Select model provider or alias") { }
            p.on("--markdown", "Enable ANSI markdown formatting in terminal") { }
            p.on("--no-markdown", "Disable ANSI markdown formatting in terminal") { }
            p.on("-v", "--version", "Show NIGHTMARE version") { }
            p.on("-h", "--help", "Show help information") { }
          end
          io << opts
        end
      end
    end

    def self.run(args : Array(String) = ARGV) : Nil
      options = Parser.parse(args)

      if err = options.error_message
        STDERR.puts "Error: #{err}"
        STDERR.puts Parser.help_text
        exit 1
      end

      if options.show_version
        puts "NIGHTMARE #{Nightmare::VERSION}"
        exit 0
      end

      if options.show_help
        puts Parser.help_text
        exit 0
      end

      # Lazily resolve target_dir: if no explicit workspace path was given via CLI,
      # resolve from Dir.current now (not at struct construction time) so that a
      # getcwd(2) failure produces a clear fatal error rather than crashing the parser.
      target = options.target_dir
      if target.empty?
        begin
          target = Dir.current
        rescue ex : File::Error
          STDERR.puts "Fatal: Cannot determine current working directory: #{ex.message}"
          STDERR.puts "The process's CWD may have been deleted. Pass an explicit workspace path as an argument."
          exit 1
        end
      end

      begin
        env = Workspace::Environment.resolve(
          target,
          ensure_dirs: !options.no_log,
          no_log: options.no_log
        )
        repl = REPL.new(
          env: env,
          system_prompt_path: options.system_prompt_path,
          model_override: options.model,
          no_log: options.no_log,
          markdown_override: options.markdown
        )
        repl.start
      rescue ex : SecurityError
        STDERR.puts "Fatal Security Violation: #{ex.message}"
        exit 1
      rescue ex : Exception
        STDERR.puts "Fatal Error: #{ex.message}"
        exit 1
      end
    end
  end
end

{% if !@top_level.has_constant?("Spec") %}
  Nightmare::CLI.run
{% end %}
