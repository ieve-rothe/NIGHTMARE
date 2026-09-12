require "./spec_helper"
require "salamander"
require "../src/nightmare/workspace/environment"
require "../src/nightmare/repl"

describe "Markdown Formatting Integration" do
  describe Nightmare::Workspace::Environment do
    it "resolves markdown formatting as true by default" do
      with_temp_dir do |dir|
        env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)
        env.resolve_markdown_formatting.should be_true
      end
    end

    it "respects CLI override over config" do
      with_temp_dir do |dir|
        env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)
        env.resolve_markdown_formatting(cli_override: false).should be_false
        env.resolve_markdown_formatting(cli_override: true).should be_true
      end
    end

    it "disables markdown formatting if NO_COLOR environment variable is set" do
      with_temp_dir do |dir|
        env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)
        ENV["NO_COLOR"] = "1"
        begin
          env.resolve_markdown_formatting.should be_false
        ensure
          ENV.delete("NO_COLOR")
        end
      end
    end

    it "reads markdown: false from settings" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          cfg_dir = File.join(xdg, "config", "nightmare")
          Dir.mkdir_p(cfg_dir)
          File.write(File.join(cfg_dir, "config.json"), %({"markdown": false}))

          env = Nightmare::Workspace::Environment.resolve(
            current_dir: dir,
            xdg_config_home: File.join(xdg, "config"),
            xdg_state_home: File.join(xdg, "state"),
            xdg_cache_home: File.join(xdg, "cache")
          )

          env.settings.markdown.should be_false
          env.resolve_markdown_formatting.should be_false
        end
      end
    end
  end

  describe Salamander::UI::MarkdownFormatter do
    it "formats markdown elements to terminal ANSI escape sequences" do
      formatted = Salamander::UI::MarkdownFormatter.format("**bold** and *italic*")
      formatted.should contain("\e[1;97mbold\e[0m")
      formatted.should contain("\e[3mitalic\e[0m")
    end

    it "formats headers with cyan bold styling" do
      formatted = Salamander::UI::MarkdownFormatter.format("# Main Header")
      formatted.should contain("\e[1;36m# Main Header\e[0m")
    end

    it "protects code blocks and applies background styling" do
      code = "```crystal\ndef hello; puts :hi; end\n```"
      formatted = Salamander::UI::MarkdownFormatter.format(code)
      formatted.should contain("\e[48;5;236m")
      formatted.should contain("def hello; puts :hi; end")
    end
  end

  describe Nightmare::REPL do
    it "initializes markdown_formatting property according to environment" do
      with_temp_dir do |dir|
        env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)
        repl = Nightmare::REPL.new(env, no_log: true)
        repl.markdown_formatting?.should be_true

        repl_no_md = Nightmare::REPL.new(env, no_log: true, markdown_override: false)
        repl_no_md.markdown_formatting?.should be_false
      end
    end
  end
end
