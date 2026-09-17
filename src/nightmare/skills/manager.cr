# nightmare/skills/manager.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "./skill"

module Nightmare::Skills
  enum ToggleStatus
    Activated
    Switched
    Deactivated
    NotFound
  end

  record ToggleResult,
    status : ToggleStatus,
    skill : Skill?,
    previous_skill : Skill?

  class SkillManager
    getter local_skills_dir : String
    getter global_skills_dir : String
    property active_skill : Skill? = nil

    def initialize(@local_skills_dir : String, @global_skills_dir : String)
    end

    def scan_all : Array(Skill)
      local_map = Hash(String, String).new
      global_map = Hash(String, String).new

      if Dir.exists?(@local_skills_dir)
        Dir.glob(File.join(@local_skills_dir, "*.md")).each do |path|
          next unless File.file?(path)
          fname = File.basename(path)
          name = fname[0...-3]
          local_map[name] = path
        end
      end

      if Dir.exists?(@global_skills_dir)
        Dir.glob(File.join(@global_skills_dir, "*.md")).each do |path|
          next unless File.file?(path)
          fname = File.basename(path)
          name = fname[0...-3]
          global_map[name] = path
        end
      end

      skills = [] of Skill

      # Process local skills first
      local_map.each do |name, path|
        skill = Skill.from_file(path, Scope::Local)
        if global_map.has_key?(name)
          skill.overrides_global = true
        end
        skills << skill
      end

      # Process global skills that are not overridden by local skills
      global_map.each do |name, path|
        next if local_map.has_key?(name)
        skills << Skill.from_file(path, Scope::Global)
      end

      skills.sort_by!(&.name)
      skills
    end

    def find(query : String) : Skill?
      clean_name = query.ends_with?(".md") ? query[0...-3] : query
      filename = "#{clean_name}.md"

      local_path = File.join(@local_skills_dir, filename)
      if File.file?(local_path)
        skill = Skill.from_file(local_path, Scope::Local)
        global_path = File.join(@global_skills_dir, filename)
        skill.overrides_global = true if File.file?(global_path)
        return skill
      end

      global_path = File.join(@global_skills_dir, filename)
      if File.file?(global_path)
        return Skill.from_file(global_path, Scope::Global)
      end

      nil
    end

    def toggle(query : String) : ToggleResult
      clean_query = query.strip
      if clean_query.downcase.in?("off", "drop", "none", "clear")
        prev = @active_skill
        @active_skill = nil
        return ToggleResult.new(ToggleStatus::Deactivated, nil, prev)
      end

      target_name = clean_query.ends_with?(".md") ? clean_query[0...-3] : clean_query
      if active = @active_skill
        if active.name == target_name
          prev = @active_skill
          @active_skill = nil
          return ToggleResult.new(ToggleStatus::Deactivated, nil, prev)
        end
      end

      target = find(clean_query)
      return ToggleResult.new(ToggleStatus::NotFound, nil, nil) unless target

      prev = @active_skill
      @active_skill = target

      if prev
        ToggleResult.new(ToggleStatus::Switched, target, prev)
      else
        ToggleResult.new(ToggleStatus::Activated, target, nil)
      end
    end

    def deactivate : Skill?
      prev = @active_skill
      @active_skill = nil
      prev
    end
  end
end
