# spec/skills_spec.cr
require "./spec_helper"
require "../src/nightmare/skills"

describe Nightmare::Skills do
  describe Nightmare::Skills::Skill do
    it "creates a skill from file with correct name, scope, and formatted block" do
      temp_dir = File.tempname("skill_spec")
      Dir.mkdir_p(temp_dir)

      begin
        path = File.join(temp_dir, "mail_sorter_v2.md")
        File.write(path, "Sort all incoming mail into Urgent and Low priority.")

        skill = Nightmare::Skills::Skill.from_file(path, Nightmare::Skills::Scope::Global)
        skill.name.should eq("mail_sorter_v2")
        skill.filename.should eq("mail_sorter_v2.md")
        skill.scope.should eq(Nightmare::Skills::Scope::Global)
        skill.overrides_global?.should be_false
        skill.content.should eq("Sort all incoming mail into Urgent and Low priority.")
        skill.formatted_block.should eq("=== ACTIVE SKILL: mail_sorter_v2 (global) ===\nSort all incoming mail into Urgent and Low priority.")
      ensure
        FileUtils.rm_rf(temp_dir)
      end
    end
  end

  describe Nightmare::Skills::SkillManager do
    it "scans local and global directories and marks overrides" do
      local_dir = File.tempname("local_skills")
      global_dir = File.tempname("global_skills")
      Dir.mkdir_p(local_dir)
      Dir.mkdir_p(global_dir)

      begin
        # Global skills
        File.write(File.join(global_dir, "sorter_v1.md"), "Global v1")
        File.write(File.join(global_dir, "shared.md"), "Global shared")
        File.write(File.join(global_dir, "unrelated.txt"), "Ignore non-md")

        # Local skills
        File.write(File.join(local_dir, "shared.md"), "Local shared override")
        File.write(File.join(local_dir, "local_only.md"), "Local only")

        manager = Nightmare::Skills::SkillManager.new(local_dir, global_dir)
        skills = manager.scan_all

        skills.size.should eq(3) # local_only, shared, sorter_v1

        local_only = skills.find { |s| s.name == "local_only" }.not_nil!
        local_only.scope.should eq(Nightmare::Skills::Scope::Local)
        local_only.overrides_global?.should be_false

        shared = skills.find { |s| s.name == "shared" }.not_nil!
        shared.scope.should eq(Nightmare::Skills::Scope::Local)
        shared.overrides_global?.should be_true
        shared.content.should eq("Local shared override")

        sorter = skills.find { |s| s.name == "sorter_v1" }.not_nil!
        sorter.scope.should eq(Nightmare::Skills::Scope::Global)
        sorter.overrides_global?.should be_false
      ensure
        FileUtils.rm_rf(local_dir)
        FileUtils.rm_rf(global_dir)
      end
    end

    it "finds skill by exact name with or without .md" do
      local_dir = File.tempname("local_skills_find")
      global_dir = File.tempname("global_skills_find")
      Dir.mkdir_p(local_dir)
      Dir.mkdir_p(global_dir)

      begin
        File.write(File.join(global_dir, "expert_v3.md"), "Expert rules")

        manager = Nightmare::Skills::SkillManager.new(local_dir, global_dir)

        s1 = manager.find("expert_v3")
        s1.should_not be_nil
        s1.not_nil!.name.should eq("expert_v3")

        s2 = manager.find("expert_v3.md")
        s2.should_not be_nil
        s2.not_nil!.name.should eq("expert_v3")

        s3 = manager.find("nonexistent")
        s3.should be_nil
      ensure
        FileUtils.rm_rf(local_dir)
        FileUtils.rm_rf(global_dir)
      end
    end

    it "handles toggling: activate -> switch -> toggle off -> explicit off" do
      local_dir = File.tempname("local_skills_toggle")
      global_dir = File.tempname("global_skills_toggle")
      Dir.mkdir_p(local_dir)
      Dir.mkdir_p(global_dir)

      begin
        File.write(File.join(global_dir, "skill_a.md"), "Skill A")
        File.write(File.join(global_dir, "skill_b.md"), "Skill B")

        manager = Nightmare::Skills::SkillManager.new(local_dir, global_dir)
        manager.active_skill.should be_nil

        # 1. Activate skill_a
        r1 = manager.toggle("skill_a")
        r1.status.should eq(Nightmare::Skills::ToggleStatus::Activated)
        r1.skill.not_nil!.name.should eq("skill_a")
        r1.previous_skill.should be_nil
        manager.active_skill.not_nil!.name.should eq("skill_a")

        # 2. Switch to skill_b
        r2 = manager.toggle("skill_b")
        r2.status.should eq(Nightmare::Skills::ToggleStatus::Switched)
        r2.skill.not_nil!.name.should eq("skill_b")
        r2.previous_skill.not_nil!.name.should eq("skill_a")
        manager.active_skill.not_nil!.name.should eq("skill_b")

        # 3. Toggle off by repeating skill_b
        r3 = manager.toggle("skill_b")
        r3.status.should eq(Nightmare::Skills::ToggleStatus::Deactivated)
        r3.previous_skill.not_nil!.name.should eq("skill_b")
        manager.active_skill.should be_nil

        # 4. Activate skill_a again
        manager.toggle("skill_a")
        manager.active_skill.not_nil!.name.should eq("skill_a")

        # 5. Explicit deactivation via /skill off
        r4 = manager.toggle("off")
        r4.status.should eq(Nightmare::Skills::ToggleStatus::Deactivated)
        r4.previous_skill.not_nil!.name.should eq("skill_a")
        manager.active_skill.should be_nil

        # 6. Toggle nonexistent
        r5 = manager.toggle("does_not_exist")
        r5.status.should eq(Nightmare::Skills::ToggleStatus::NotFound)
        manager.active_skill.should be_nil
      ensure
        FileUtils.rm_rf(local_dir)
        FileUtils.rm_rf(global_dir)
      end
    end
  end
end
