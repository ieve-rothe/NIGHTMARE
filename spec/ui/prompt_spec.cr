require "../spec_helper"
require "../../src/nightmare/ui/prompt"

describe Nightmare::UI::Prompt do
  describe ".format_path" do
    it "replaces exact home directory with ~" do
      Nightmare::UI::Prompt.format_path("/home/user", home: "/home/user").should eq("~")
    end

    it "handles trailing slash in home directory" do
      Nightmare::UI::Prompt.format_path("/home/user", home: "/home/user/").should eq("~")
    end

    it "replaces home prefix in subdirectories with ~/" do
      Nightmare::UI::Prompt.format_path("/home/user/repos/project", home: "/home/user").should eq("~/repos/project")
    end

    it "leaves paths outside home directory untouched" do
      Nightmare::UI::Prompt.format_path("/var/log/syslog", home: "/home/user").should eq("/var/log/syslog")
    end

    it "does not replace directory names that merely share a prefix with home" do
      Nightmare::UI::Prompt.format_path("/home/user2/repos", home: "/home/user").should eq("/home/user2/repos")
    end
  end

  describe ".render" do
    it "renders formatted path and prompt glyph" do
      res = Nightmare::UI::Prompt.render(
        cwd: "/home/user/repos/adjutant",
        active_skill_name: nil,
        home: "/home/user"
      )

      res.should contain("~/repos/adjutant")
      res.should contain(Salamander::UI::Theme.prompt_glyph.to_s)
      res.should_not contain("[deploy-runner]")
    end

    it "includes active skill tag when present" do
      res = Nightmare::UI::Prompt.render(
        cwd: "/home/user/repos/adjutant",
        active_skill_name: "deploy-runner",
        home: "/home/user"
      )

      res.should contain("~/repos/adjutant")
      res.should contain("[deploy-runner]")
      res.should contain(Salamander::UI::Theme.prompt_glyph.to_s)
    end
  end
end
