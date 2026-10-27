require "option_parser"
require "colorize"
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
  VERSION = "0.7.0"

  module CLI
    class Options
      property system_prompt_path : String? = nil
      property no_log : Bool = false
      property model : String? = nil
      property markdown : Bool? = nil
      property target_dir : String = ""
      property readable_directories : Array(String) = [] of String
      property writable_directories : Array(String) = [] of String
      property show_help : Bool = false
      property show_version : Bool = false
      property error_message : String? = nil
    end

    class Parser
      def self.build(options : Options = Options.new) : OptionParser
        OptionParser.new do |opts|
          opts.banner = "NIGHTMARE - Developer REPL\nUsage: nightmare [options] [workspace_path]"

          opts.on("-s PATH", "--system=PATH", "Path to custom system prompt file (overrides all defaults)") do |path|
            options.system_prompt_path = path
          end

          opts.on("-R PATH", "--read-dir=PATH", "Designate an external directory as globally readable (can be repeated)") do |path|
            options.readable_directories << path
          end

          opts.on("-W PATH", "--write-dir=PATH", "Designate an external directory as globally writable (can be repeated)") do |path|
            options.writable_directories << path
          end

          opts.on("--writable-dir=PATH", "--writeable-dir=PATH", "Designate an external directory as globally writable (can be repeated)") do |path|
            options.writable_directories << path
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
      end

      def self.parse(args : Array(String) = ARGV) : Options
        options = Options.new
        parser = build(options)

        begin
          parser.parse(args)
        rescue ex : OptionParser::InvalidOption | OptionParser::MissingOption
          options.error_message = ex.message
        end

        options
      end

      def self.help_text : String
        build(Options.new).to_s
      end
    end

    def self.execute(
      args : Array(String) = ARGV,
      stdin : IO = STDIN,
      stdout : IO = STDOUT,
      stderr : IO = STDERR,
      & : REPL -> Nil
    ) : Int32
      options = Parser.parse(args)

      if err = options.error_message
        stderr.puts "Error: #{err}".colorize(:red)
        if err.starts_with?("Invalid option")
          cli_flags = %w(--system -s --read-dir -R --write-dir -W --no-logs --no-log --model -m --markdown --no-markdown --version -v --help -h)
          if flag_match = err.match(/(-{1,2}[a-zA-Z0-9_\-]+)/)
            flag = flag_match[1]
            if suggestion = Salamander::Fuzzy.find_closest(flag, cli_flags)
              stderr.puts "💡 Did you mean '#{suggestion}'?".colorize(:yellow)
            end
          end
        end
        stderr.puts Parser.help_text
        return 1
      end

      if options.show_version
        stdout.puts "NIGHTMARE #{Nightmare::VERSION}"
        return 0
      end

      if options.show_help
        stdout.puts Parser.help_text
        return 0
      end

      # Lazily resolve target_dir: if no explicit workspace path was given via CLI,
      # resolve from Dir.current now (not at struct construction time) so that a
      # getcwd(2) failure produces a clear fatal error rather than crashing the parser.
      target = options.target_dir
      if target.empty?
        begin
          target = Dir.current
        rescue ex : File::Error
          stderr.puts "Fatal: Cannot determine current working directory: #{ex.message}"
          stderr.puts "The process's CWD may have been deleted. Pass an explicit workspace path as an argument."
          return 1
        end
      end

      begin
        env = Workspace::Environment.resolve(
          target,
          ensure_dirs: !options.no_log,
          no_log: options.no_log,
          cli_readable_directories: options.readable_directories,
          cli_writable_directories: options.writable_directories
        )
        repl = REPL.new(
          env: env,
          system_prompt_path: options.system_prompt_path,
          model_override: options.model,
          no_log: options.no_log,
          markdown_override: options.markdown
        )
        yield repl
        0
      rescue ex : SecurityError
        stderr.puts "Fatal Security Violation: #{ex.message}".colorize(:red)
        1
      rescue ex : Exception
        stderr.puts "Fatal Error: #{ex.message}".colorize(:red)
        1
      end
    end

    def self.execute(
      args : Array(String) = ARGV,
      stdin : IO = STDIN,
      stdout : IO = STDOUT,
      stderr : IO = STDERR,
    ) : Int32
      execute(args, stdin, stdout, stderr) do |repl|
        repl.start
      end
    end

    def self.run(args : Array(String) = ARGV) : Nil
      exit execute(args)
    end
  end
end

{% if !@top_level.has_constant?("Spec") %}
  Nightmare::CLI.run
{% end %}
