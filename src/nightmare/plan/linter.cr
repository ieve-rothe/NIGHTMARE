# nightmare/plan/linter.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "./models"

module Nightmare::Plan
  record LintFinding,
    severity : String, # "error" or "warning"
    item_id : String?,
    message : String

  class Linter
    getter plan : Plan

    def initialize(@plan : Plan)
    end

    def lint(primary_repo_path : String? = nil) : Array(LintFinding)
      findings = [] of LintFinding

      # 1. Dependency cycle and existence checks
      lint_dependencies(findings)

      # 2. Target files checks
      lint_targets(findings)

      # 3. Author vs Grader separation check
      lint_author_grader_separation(findings)

      # 4. Git status check if primary repo path provided
      if repo = primary_repo_path
        lint_git_clean(repo, findings)
      end

      findings
    end

    private def lint_dependencies(findings : Array(LintFinding)) : Nil
      all_ids = @plan.items.map(&.id).to_set

      @plan.items.each do |item|
        item.depends_on.each do |dep_id|
          unless all_ids.includes?(dep_id)
            findings << LintFinding.new(
              severity: "error",
              item_id: item.id,
              message: "Unknown dependency '#{dep_id}' declared in depends_on."
            )
          end
        end
      end

      # Cycle detection using DFS
      visited = Hash(String, Int32).new(0) # 0: unvisited, 1: visiting, 2: visited

      @plan.items.each do |item|
        if visited[item.id] == 0
          if has_cycle?(item.id, visited)
            findings << LintFinding.new(
              severity: "error",
              item_id: item.id,
              message: "Cyclic dependency detected in depends_on graph involving item '#{item.id}'."
            )
          end
        end
      end
    end

    private def has_cycle?(item_id : String, visited : Hash(String, Int32)) : Bool
      visited[item_id] = 1 # visiting

      item = @plan.find_item(item_id)
      if item
        item.depends_on.each do |dep_id|
          state = visited[dep_id]
          if state == 1
            return true # cycle detected
          elsif state == 0
            return true if has_cycle?(dep_id, visited)
          end
        end
      end

      visited[item_id] = 2 # visited
      false
    end

    private def lint_targets(findings : Array(LintFinding)) : Nil
      @plan.items.each do |item|
        if item.profile_id != "researcher" && item.files_targeted.empty? && item.verification.kind != VerificationKind::None
          findings << LintFinding.new(
            severity: "error",
            item_id: item.id,
            message: "Mutator item '#{item.id}' declares empty files_targeted."
          )
        end
      end
    end

    private def lint_author_grader_separation(findings : Array(LintFinding)) : Nil
      @plan.items.each do |item|
        has_src = item.files_targeted.any? { |p| p.starts_with?("src/") || (!p.includes?("spec") && !p.includes?("test")) }
        has_spec = item.files_targeted.any? { |p| p.includes?("spec") || p.includes?("test") }

        if has_src && has_spec && item.verification.kind == VerificationKind::Command && item.verification.expect == "no_new_failures"
          findings << LintFinding.new(
            severity: "warning",
            item_id: item.id,
            message: "Author/grader overlap: item targets both implementation code and verifying specs. Consider separating into Step A (author failing spec) and Step B (implement fix)."
          )
        end
      end
    end

    private def lint_git_clean(repo_path : String, findings : Array(LintFinding)) : Nil
      res = Process.run("git", ["status", "--porcelain"], chdir: repo_path, output: Process::Redirect::Pipe)
      # If git command failed or repo is dirty
      if !res.success?
        findings << LintFinding.new(
          severity: "error",
          item_id: nil,
          message: "Failed to check git status in primary repo '#{repo_path}'."
        )
      end
    end
  end
end
