# spec/plan/linter_spec.cr
require "../spec_helper"

describe Nightmare::Plan::Linter do
  it "detects cyclic dependencies in depends_on graph" do
    item1 = Nightmare::Plan::PlanItem.new(
      id: "item-a",
      title: "Step A",
      depends_on: ["item-b"]
    )
    item2 = Nightmare::Plan::PlanItem.new(
      id: "item-b",
      title: "Step B",
      depends_on: ["item-a"]
    )

    plan = Nightmare::Plan::Plan.new(
      id: "cycle-plan",
      goal: "Test cycles",
      items: [item1, item2]
    )

    linter = Nightmare::Plan::Linter.new(plan)
    findings = linter.lint

    findings.any? { |f| f.message.includes?("Cyclic dependency") }.should be_true
  end

  it "detects unknown dependencies in depends_on graph" do
    item = Nightmare::Plan::PlanItem.new(
      id: "item-solo",
      title: "Solo",
      depends_on: ["does-not-exist"]
    )

    plan = Nightmare::Plan::Plan.new(
      id: "unknown-dep-plan",
      goal: "Test unknown dep",
      items: [item]
    )

    linter = Nightmare::Plan::Linter.new(plan)
    findings = linter.lint

    findings.any? { |f| f.message.includes?("Unknown dependency 'does-not-exist'") }.should be_true
  end

  it "warns on author/grader separation overlap" do
    item = Nightmare::Plan::PlanItem.new(
      id: "item-overlap",
      title: "Edits both code and test",
      files_targeted: ["src/nightmare/cli.cr", "spec/cli_spec.cr"],
      verification: Nightmare::Plan::VerificationConfig.new(
        kind: Nightmare::Plan::VerificationKind::Command,
        command: ["crystal", "spec"],
        expect: "no_new_failures"
      )
    )

    plan = Nightmare::Plan::Plan.new(
      id: "overlap-plan",
      goal: "Test author/grader warning",
      items: [item]
    )

    linter = Nightmare::Plan::Linter.new(plan)
    findings = linter.lint

    findings.any? { |f| f.severity == "warning" && f.message.includes?("Author/grader overlap") }.should be_true
  end
end
