# nightmare/plan/worktree.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "file_utils"

module Nightmare::Plan
  class WorktreeError < Exception
  end

  class Worktree
    getter primary_root : String
    getter worktree_path : String
    getter cache_dir : String
    getter branch_name : String

    def initialize(
      @primary_root : String,
      @worktree_path : String,
      @cache_dir : String,
      @branch_name : String = "nightmare/plan-execution"
    )
      @primary_root = File.realpath(@primary_root)
      @worktree_path = File.expand_path(@worktree_path)
      @cache_dir = File.expand_path(@cache_dir)
    end

    # Provisions the isolated git worktree outside the primary repository
    def provision(base_ref : String? = nil, setup_command : Array(String)? = nil) : String
      # Safety check: primary root must be a git repo
      unless Dir.exists?(File.join(@primary_root, ".git")) || File.exists?(File.join(@primary_root, ".git"))
        raise WorktreeError.new("Primary root '#{@primary_root}' is not a git repository.")
      end

      # Refuse if primary worktree is dirty
      if dirty?(@primary_root)
        raise WorktreeError.new("Primary repository has uncommitted changes. Please stash or commit before running plan.")
      end

      head_sha = get_head_sha(@primary_root)

      # Ensure parent dir of worktree exists
      Dir.mkdir_p(File.dirname(@worktree_path))
      Dir.mkdir_p(@cache_dir)

      # If worktree already exists, remove or reuse cleanly
      if Dir.exists?(@worktree_path)
        # Check if it's already a valid worktree
        if File.exists?(File.join(@worktree_path, ".git"))
          assert_managed_worktree!(@worktree_path)
          run_git(@worktree_path, ["reset", "--hard", head_sha])
          run_git(@worktree_path, ["clean", "-fd"])
        else
          FileUtils.rm_rf(@worktree_path)
          create_worktree(base_ref || head_sha)
        end
      else
        create_worktree(base_ref || head_sha)
      end

      # Run setup command (e.g. shards install) with isolated CRYSTAL_CACHE_DIR
      if setup_cmd = setup_command
        run_setup(setup_cmd)
      end

      head_sha
    end

    # Executes setup command in the worktree
    private def run_setup(cmd : Array(String)) : Nil
      assert_managed_worktree!(@worktree_path)
      env = {
        "CRYSTAL_CACHE_DIR" => @cache_dir,
        "CI"                => "1",
      }

      status = Process.run(
        cmd.first,
        cmd[1..],
        chdir: @worktree_path,
        env: env,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe
      )

      unless status.success?
        raise WorktreeError.new("Worktree setup command '#{cmd.join(" ")}' failed with exit code #{status.exit_code}")
      end
    end

    # Creates the git worktree
    private def create_worktree(commit_or_ref : String) : Nil
      # Delete existing branch if needed
      run_git(@primary_root, ["branch", "-D", @branch_name], raise_on_error: false)

      res = run_git(@primary_root, ["worktree", "add", "-B", @branch_name, @worktree_path, commit_or_ref])
      unless res[:success]
        raise WorktreeError.new("Failed to add git worktree at '#{@worktree_path}': #{res[:error]}")
      end
    end

    # Commits current worktree changes as an item checkpoint
    def commit_checkpoint(item_id : String, title : String) : String
      assert_managed_worktree!(@worktree_path)

      if diff_empty?
        # Nothing changed (e.g. research task), return current HEAD
        return get_head_sha(@worktree_path)
      end

      # Stage all changes
      run_git(@worktree_path, ["add", "-A"])
      commit_msg = "nightmare(plan): [#{item_id}] #{title}"

      res = run_git(@worktree_path, ["commit", "-m", commit_msg])
      unless res[:success]
        raise WorktreeError.new("Failed to commit checkpoint for item '#{item_id}': #{res[:error]}")
      end

      get_head_sha(@worktree_path)
    end

    # Archives a dirty diff before hard rollback
    def archive_failure_patch(archive_path : String) : Nil
      assert_managed_worktree!(@worktree_path)
      diff = capture_diff(@worktree_path)
      return if diff.empty?

      Dir.mkdir_p(File.dirname(archive_path))
      File.write(archive_path, diff)
    end

    # Hard rolls back the worktree to a target base SHA
    def rollback_to(base_sha : String) : Nil
      assert_managed_worktree!(@worktree_path)

      # 1. Hard reset to base SHA
      res_reset = run_git(@worktree_path, ["reset", "--hard", base_sha])
      unless res_reset[:success]
        raise WorktreeError.new("Failed to reset worktree to #{base_sha}: #{res_reset[:error]}")
      end

      # 2. Clean untracked files strictly within worktree
      res_clean = run_git(@worktree_path, ["clean", "-fd"])
      unless res_clean[:success]
        raise WorktreeError.new("Failed to clean worktree: #{res_clean[:error]}")
      end
    end

    # Captures current git diff in worktree (staged + unstaged)
    def capture_diff(dir : String = @worktree_path) : String
      res = run_git(dir, ["diff", "HEAD"])
      if res[:success]
        res[:output]
      else
        res_unstaged = run_git(dir, ["diff"])
        res_unstaged[:output]
      end
    end

    # Checks if worktree has any diff or untracked files
    def diff_empty?(dir : String = @worktree_path) : Bool
      capture_diff(dir).strip.empty? && !has_untracked_files?(dir)
    end

    def has_untracked_files?(dir : String = @worktree_path) : Bool
      res = run_git(dir, ["status", "--porcelain"])
      !res[:output].strip.empty?
    end

    def get_head_sha(dir : String) : String
      res = run_git(dir, ["rev-parse", "HEAD"])
      if res[:success]
        res[:output].strip
      else
        raise WorktreeError.new("Failed to get HEAD SHA for '#{dir}': #{res[:error]}")
      end
    end

    def dirty?(dir : String) : Bool
      res = run_git(dir, ["status", "--porcelain"])
      !res[:output].strip.empty?
    end

    # Safety guard: ensures directory is inside the managed worktree, never the primary root
    def assert_managed_worktree!(path : String) : Nil
      real_path = File.realpath(path)
      real_primary = @primary_root

      if real_path == real_primary || real_path.starts_with?("#{real_primary}/")
        raise WorktreeError.new("Safety violation: attempted git clean/reset against primary checkout: #{real_path}")
      end

      unless real_path == @worktree_path || real_path.starts_with?("#{@worktree_path}/")
        raise WorktreeError.new("Safety violation: path '#{real_path}' is outside managed worktree '#{@worktree_path}'")
      end
    end

    # Runs git with disabled hooks
    def run_git(cwd : String, args : Array(String), raise_on_error : Bool = true) : NamedTuple(success: Bool, output: String, error: String, exit_code: Int32)
      cmd_args = ["-c", "core.hooksPath=/dev/null"] + args
      out_io = IO::Memory.new
      err_io = IO::Memory.new

      status = Process.run(
        "git",
        cmd_args,
        chdir: cwd,
        output: out_io,
        error: err_io
      )

      out_str = out_io.to_s
      err_str = err_io.to_s

      if !status.success? && raise_on_error
        # don't raise immediately; caller checks success
      end

      {
        success:   status.success?,
        output:    out_str,
        error:     err_str,
        exit_code: status.exit_code,
      }
    end
  end
end
