# spec/plan/orchestrator_spec.cr
require "../spec_helper"

class MockSubagentDispatcher < Nightmare::Plan::SubagentDispatcher
  property behaviors : Hash(String, Array(Proc(String, NamedTuple(
    status: String,
    summary: String,
    files_touched: Array(String),
    tool_calls_count: Int32,
    shell_commands: Array(Nightmare::Plan::ExecutedCommand),
    proposed_items: Array(Nightmare::Plan::ProposedItem),
    proposed_targets: Array(String),
    tokens_used: Int32
  )))) = {} of String => Array(Proc(String, NamedTuple(
    status: String,
    summary: String,
    files_touched: Array(String),
    tool_calls_count: Int32,
    shell_commands: Array(Nightmare::Plan::ExecutedCommand),
    proposed_items: Array(Nightmare::Plan::ProposedItem),
    proposed_targets: Array(String),
    tokens_used: Int32
  )))

  def on_item(item_id : String, &block : String -> NamedTuple(
    status: String,
    summary: String,
    files_touched: Array(String),
    tool_calls_count: Int32,
    shell_commands: Array(Nightmare::Plan::ExecutedCommand),
    proposed_items: Array(Nightmare::Plan::ProposedItem),
    proposed_targets: Array(String),
    tokens_used: Int32
  ))
    @behaviors[item_id] ||= [] of Proc(String, NamedTuple(
      status: String,
      summary: String,
      files_touched: Array(String),
      tool_calls_count: Int32,
      shell_commands: Array(Nightmare::Plan::ExecutedCommand),
      proposed_items: Array(Nightmare::Plan::ProposedItem),
      proposed_targets: Array(String),
      tokens_used: Int32
    ))
    @behaviors[item_id] << block
  end

  def dispatch(
    item : Nightmare::Plan::PlanItem,
    run : Nightmare::Plan::PlanRun,
    worktree_path : String
  ) : NamedTuple(
    status: String,
    summary: String,
    files_touched: Array(String),
    tool_calls_count: Int32,
    shell_commands: Array(Nightmare::Plan::ExecutedCommand),
    proposed_items: Array(Nightmare::Plan::ProposedItem),
    proposed_targets: Array(String),
    tokens_used: Int32
  )
    queue = @behaviors[item.id]?
    if queue && !queue.empty?
      block = queue.shift
      block.call(worktree_path)
    else
      {
        status: "completed",
        summary: "Default completion for #{item.id}",
        files_touched: [] of String,
        tool_calls_count: 1,
        shell_commands: [] of Nightmare::Plan::ExecutedCommand,
        proposed_items: [] of Nightmare::Plan::ProposedItem,
        proposed_targets: [] of String,
        tokens_used: 100,
      }
    end
  end
end

def init_git_repo(path : String) : String
  Process.run("git", ["init", "-b", "main"], chdir: path)
  Process.run("git", ["config", "user.name", "TestUser"], chdir: path)
  Process.run("git", ["config", "user.email", "test@test.org"], chdir: path)
  File.write(File.join(path, "README.md"), "# Test Repo\n")
  Process.run("git", ["add", "README.md"], chdir: path)
  Process.run("git", ["commit", "-m", "Initial commit"], chdir: path)
  res = Process.run("git", ["rev-parse", "HEAD"], chdir: path, output: Process::Redirect::Pipe)
  # Read SHA
  File.read(File.join(path, ".git", "refs", "heads", "main")).strip
end

describe Nightmare::Plan::Orchestrator do
  it "executes a 3-item plan to completion with automated git checkpoint commits" do
    with_temp_dir do |temp_dir|
      repo_dir = File.join(temp_dir, "repo")
      worktree_dir = File.join(temp_dir, "worktree")
      runs_dir = File.join(temp_dir, "runs")
      cache_dir = File.join(temp_dir, "cache")
      Dir.mkdir_p(repo_dir)

      init_git_repo(repo_dir)

      item1 = Nightmare::Plan::PlanItem.new(
        id: "item-1",
        title: "Research architecture",
        profile_id: "researcher",
        verification: Nightmare::Plan::VerificationConfig.new(kind: Nightmare::Plan::VerificationKind::None)
      )
      item2 = Nightmare::Plan::PlanItem.new(
        id: "item-2",
        title: "Create module A",
        profile_id: "code_modifier",
        depends_on: ["item-1"],
        verification: Nightmare::Plan::VerificationConfig.new(kind: Nightmare::Plan::VerificationKind::DiffNonEmpty)
      )
      item3 = Nightmare::Plan::PlanItem.new(
        id: "item-3",
        title: "Create module B",
        profile_id: "code_modifier",
        depends_on: ["item-2"],
        verification: Nightmare::Plan::VerificationConfig.new(kind: Nightmare::Plan::VerificationKind::DiffNonEmpty)
      )

      plan = Nightmare::Plan::Plan.new(
        id: "plan-happy-path",
        goal: "Test full progression",
        items: [item1, item2, item3]
      )

      dispatcher = MockSubagentDispatcher.new

      # Item 1: researcher does no edits
      dispatcher.on_item("item-1") do |_wt|
        {
          status: "completed",
          summary: "Researched codebase",
          files_touched: [] of String,
          tool_calls_count: 2,
          shell_commands: [] of Nightmare::Plan::ExecutedCommand,
          proposed_items: [] of Nightmare::Plan::ProposedItem,
          proposed_targets: [] of String,
          tokens_used: 200,
        }
      end

      # Item 2: writes a.cr
      dispatcher.on_item("item-2") do |wt|
        File.write(File.join(wt, "a.cr"), "module A; end\n")
        {
          status: "completed",
          summary: "Created a.cr",
          files_touched: ["a.cr"],
          tool_calls_count: 3,
          shell_commands: [] of Nightmare::Plan::ExecutedCommand,
          proposed_items: [] of Nightmare::Plan::ProposedItem,
          proposed_targets: [] of String,
          tokens_used: 400,
        }
      end

      # Item 3: writes b.cr
      dispatcher.on_item("item-3") do |wt|
        File.write(File.join(wt, "b.cr"), "module B; end\n")
        {
          status: "completed",
          summary: "Created b.cr",
          files_touched: ["b.cr"],
          tool_calls_count: 3,
          shell_commands: [] of Nightmare::Plan::ExecutedCommand,
          proposed_items: [] of Nightmare::Plan::ProposedItem,
          proposed_targets: [] of String,
          tokens_used: 400,
        }
      end

      worktree = Nightmare::Plan::Worktree.new(repo_dir, worktree_dir, cache_dir)
      orchestrator = Nightmare::Plan::Orchestrator.new(
        plan: plan,
        worktree: worktree,
        dispatcher: dispatcher,
        runs_dir: runs_dir
      )

      final_run = orchestrator.run_plan("run-happy-1")

      final_run.status.should eq(Nightmare::Plan::PlanRunStatus::Completed)
      final_run.items["item-1"].status.should eq(Nightmare::Plan::PlanItemStatus::Completed)
      final_run.items["item-2"].status.should eq(Nightmare::Plan::PlanItemStatus::Completed)
      final_run.items["item-3"].status.should eq(Nightmare::Plan::PlanItemStatus::Completed)

      # Git commits should exist in worktree
      final_run.items["item-2"].result_sha.should_not be_nil
      final_run.items["item-3"].result_sha.should_not be_nil
      final_run.items["item-3"].result_sha.should_not eq(final_run.items["item-2"].result_sha)
    end
  end

  it "enforces that the gate is the sole authority: fails item if diff is empty despite worker claiming completed" do
    with_temp_dir do |temp_dir|
      repo_dir = File.join(temp_dir, "repo")
      worktree_dir = File.join(temp_dir, "worktree")
      runs_dir = File.join(temp_dir, "runs")
      cache_dir = File.join(temp_dir, "cache")
      Dir.mkdir_p(repo_dir)

      init_git_repo(repo_dir)

      item = Nightmare::Plan::PlanItem.new(
        id: "item-empty-diff",
        title: "Claims work but makes no diff",
        profile_id: "code_modifier",
        verification: Nightmare::Plan::VerificationConfig.new(kind: Nightmare::Plan::VerificationKind::DiffNonEmpty),
        max_attempts: 1
      )

      plan = Nightmare::Plan::Plan.new(
        id: "plan-empty-diff",
        goal: "Test gate sole authority",
        items: [item]
      )

      dispatcher = MockSubagentDispatcher.new
      dispatcher.on_item("item-empty-diff") do |_wt|
        # Worker proudly declares completed, but wrote nothing!
        {
          status: "completed",
          summary: "I completed everything perfectly!",
          files_touched: [] of String,
          tool_calls_count: 1,
          shell_commands: [] of Nightmare::Plan::ExecutedCommand,
          proposed_items: [] of Nightmare::Plan::ProposedItem,
          proposed_targets: [] of String,
          tokens_used: 150,
        }
      end

      worktree = Nightmare::Plan::Worktree.new(repo_dir, worktree_dir, cache_dir)
      orchestrator = Nightmare::Plan::Orchestrator.new(
        plan: plan,
        worktree: worktree,
        dispatcher: dispatcher,
        runs_dir: runs_dir
      )

      final_run = orchestrator.run_plan("run-empty-diff")

      # Item must be failed because diff was empty!
      final_run.items["item-empty-diff"].status.should eq(Nightmare::Plan::PlanItemStatus::Failed)
      final_run.status.should eq(Nightmare::Plan::PlanRunStatus::Failed)
    end
  end

  it "propagates failure in DAG: transitive dependents of a failed item transition to Skipped" do
    with_temp_dir do |temp_dir|
      repo_dir = File.join(temp_dir, "repo")
      worktree_dir = File.join(temp_dir, "worktree")
      runs_dir = File.join(temp_dir, "runs")
      cache_dir = File.join(temp_dir, "cache")
      Dir.mkdir_p(repo_dir)

      init_git_repo(repo_dir)

      item1 = Nightmare::Plan::PlanItem.new(
        id: "item-root-fail",
        title: "Root item that fails",
        verification: Nightmare::Plan::VerificationConfig.new(kind: Nightmare::Plan::VerificationKind::DiffNonEmpty),
        max_attempts: 1
      )
      item2 = Nightmare::Plan::PlanItem.new(
        id: "item-dep-1",
        title: "Direct dependent",
        depends_on: ["item-root-fail"]
      )
      item3 = Nightmare::Plan::PlanItem.new(
        id: "item-dep-2",
        title: "Transitive dependent",
        depends_on: ["item-dep-1"]
      )

      plan = Nightmare::Plan::Plan.new(
        id: "plan-failure-prop",
        goal: "Test failure propagation",
        items: [item1, item2, item3]
      )

      dispatcher = MockSubagentDispatcher.new
      dispatcher.on_item("item-root-fail") do |_wt|
        # Produces no diff -> fails
        {
          status: "completed",
          summary: "Failed work",
          files_touched: [] of String,
          tool_calls_count: 1,
          shell_commands: [] of Nightmare::Plan::ExecutedCommand,
          proposed_items: [] of Nightmare::Plan::ProposedItem,
          proposed_targets: [] of String,
          tokens_used: 100,
        }
      end

      worktree = Nightmare::Plan::Worktree.new(repo_dir, worktree_dir, cache_dir)
      orchestrator = Nightmare::Plan::Orchestrator.new(
        plan: plan,
        worktree: worktree,
        dispatcher: dispatcher,
        runs_dir: runs_dir
      )

      final_run = orchestrator.run_plan("run-fail-prop")

      final_run.items["item-root-fail"].status.should eq(Nightmare::Plan::PlanItemStatus::Failed)
      final_run.items["item-dep-1"].status.should eq(Nightmare::Plan::PlanItemStatus::Skipped)
      final_run.items["item-dep-2"].status.should eq(Nightmare::Plan::PlanItemStatus::Skipped)
      final_run.status.should eq(Nightmare::Plan::PlanRunStatus::Failed)
    end
  end

  it "parks item as Blocked and propagates Blocked down DAG on BlockedOnApproval" do
    with_temp_dir do |temp_dir|
      repo_dir = File.join(temp_dir, "repo")
      worktree_dir = File.join(temp_dir, "worktree")
      runs_dir = File.join(temp_dir, "runs")
      cache_dir = File.join(temp_dir, "cache")
      Dir.mkdir_p(repo_dir)

      init_git_repo(repo_dir)

      item1 = Nightmare::Plan::PlanItem.new(
        id: "item-blocked",
        title: "Needs out of grant permission"
      )
      item2 = Nightmare::Plan::PlanItem.new(
        id: "item-dep-blocked",
        title: "Dependent on blocked",
        depends_on: ["item-blocked"]
      )

      plan = Nightmare::Plan::Plan.new(
        id: "plan-blocked-test",
        goal: "Test blocked propagation",
        items: [item1, item2]
      )

      dispatcher = MockSubagentDispatcher.new
      dispatcher.on_item("item-blocked") do |_wt|
        {
          status: "blocked_on_approval",
          summary: "Attempted to modify protected file",
          files_touched: [] of String,
          tool_calls_count: 1,
          shell_commands: [] of Nightmare::Plan::ExecutedCommand,
          proposed_items: [] of Nightmare::Plan::ProposedItem,
          proposed_targets: [] of String,
          tokens_used: 100,
        }
      end

      worktree = Nightmare::Plan::Worktree.new(repo_dir, worktree_dir, cache_dir)
      orchestrator = Nightmare::Plan::Orchestrator.new(
        plan: plan,
        worktree: worktree,
        dispatcher: dispatcher,
        runs_dir: runs_dir
      )

      final_run = orchestrator.run_plan("run-blocked")

      final_run.items["item-blocked"].status.should eq(Nightmare::Plan::PlanItemStatus::Blocked)
      final_run.items["item-dep-blocked"].status.should eq(Nightmare::Plan::PlanItemStatus::Blocked)
      final_run.status.should eq(Nightmare::Plan::PlanRunStatus::Partial)
    end
  end

  it "aborts looping attempts on thrash detection" do
    with_temp_dir do |temp_dir|
      repo_dir = File.join(temp_dir, "repo")
      worktree_dir = File.join(temp_dir, "worktree")
      runs_dir = File.join(temp_dir, "runs")
      cache_dir = File.join(temp_dir, "cache")
      Dir.mkdir_p(repo_dir)

      init_git_repo(repo_dir)

      item = Nightmare::Plan::PlanItem.new(
        id: "item-thrasher",
        title: "Repeats identical failure",
        verification: Nightmare::Plan::VerificationConfig.new(kind: Nightmare::Plan::VerificationKind::DiffNonEmpty),
        max_attempts: 5 # Allows 5 attempts, but should abort on attempt 2 due to thrash!
      )

      plan = Nightmare::Plan::Plan.new(
        id: "plan-thrash-test",
        goal: "Test thrash abort",
        items: [item]
      )

      dispatcher = MockSubagentDispatcher.new
      # Worker repeats the exact same empty diff or failure
      dispatcher.on_item("item-thrasher") do |_wt|
        {
          status: "completed",
          summary: "Flailing with no diff",
          files_touched: [] of String,
          tool_calls_count: 1,
          shell_commands: [] of Nightmare::Plan::ExecutedCommand,
          proposed_items: [] of Nightmare::Plan::ProposedItem,
          proposed_targets: [] of String,
          tokens_used: 100,
        }
      end
      dispatcher.on_item("item-thrasher") do |_wt|
        {
          status: "completed",
          summary: "Flailing with no diff again",
          files_touched: [] of String,
          tool_calls_count: 1,
          shell_commands: [] of Nightmare::Plan::ExecutedCommand,
          proposed_items: [] of Nightmare::Plan::ProposedItem,
          proposed_targets: [] of String,
          tokens_used: 100,
        }
      end

      worktree = Nightmare::Plan::Worktree.new(repo_dir, worktree_dir, cache_dir)
      orchestrator = Nightmare::Plan::Orchestrator.new(
        plan: plan,
        worktree: worktree,
        dispatcher: dispatcher,
        runs_dir: runs_dir
      )

      final_run = orchestrator.run_plan("run-thrash")

      final_run.items["item-thrasher"].status.should eq(Nightmare::Plan::PlanItemStatus::Failed)
      final_run.items["item-thrasher"].attempts.should eq(2) # Aborted on 2, didn't burn all 5!
      final_run.items["item-thrasher"].error_history.last.should contain("Thrash detected")
    end
  end
end
