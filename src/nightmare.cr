require "option_parser"
require "mantle"
require "salamander"
require "./nightmare/exceptions"
require "./nightmare/config"
require "./nightmare/workspace/manifest"
require "./nightmare/workspace/environment"
require "./nightmare/directives/resolver"
require "./nightmare/harness/types"
require "./nightmare/tools/guard"
require "./nightmare/context/turn"
require "./nightmare/context/token_calibrator"
require "./nightmare/context/pinned_files"
require "./nightmare/context/shedder"
require "./nightmare/context/sliding_store"
require "./nightmare/transcript"

module Nightmare
  VERSION = "0.1.0"

  module CLI
    struct Options
      property system_prompt_path : String? = nil
      property no_log : Bool = false
      property model : String? = nil
      property target_dir : String = Dir.current
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

          opts.on("--no-log", "Disable LLM audit call logging in central state directory") do
            options.no_log = true
          end

          opts.on("-m MODEL", "--model=MODEL", "Select model provider or alias") do |model|
            options.model = model
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
            p.banner = "Usage: nightmare [options] [workspace_path]"
            p.on("-s PATH", "--system=PATH", "Path to custom system prompt file") { }
            p.on("--no-log", "Disable LLM audit call logging") { }
            p.on("-m MODEL", "--model=MODEL", "Select model provider or alias") { }
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

      begin
        env = Workspace::Environment.resolve(options.target_dir)
        puts env.startup_banner
      rescue ex : SecurityError
        STDERR.puts "Fatal Security Violation: #{ex.message}"
        exit 1
      rescue ex : Exception
        STDERR.puts "Fatal Initialization Error: #{ex.message}"
        exit 1
      end

      begin
        directive_buffer = Directives::Resolver.resolve_manager(env, options.system_prompt_path)
      rescue ex : ArgumentError
        STDERR.puts "Directive Error: #{ex.message}"
        exit 1
      end

      # REPL interactive loop will be wired up in downstream milestones
    end
  end
end

{% if !@top_level.has_constant?("Spec") %}
  Nightmare::CLI.run
{% end %}
