# spec/plan/verification_spec.cr
require "../spec_helper"

describe Nightmare::Plan::VerificationEngine do
  it "parses JUnit XML and extracts nested test description paths" do
    xml = <<-XML
    <?xml version="1.0" encoding="UTF-8"?>
    <testsuite name="NightmareSpec" tests="3" failures="1" errors="0">
      <testcase classname="Nightmare::CLI" name="--help flag prints banner" />
      <testcase classname="Nightmare::CLI" name="--headless flag disables spinner">
        <failure message="Expected true but got false">Error backtrace</failure>
      </testcase>
      <testcase classname="Nightmare::Context" name="prunes completed turns" />
    </testsuite>
    XML

    parser = Nightmare::Plan::JUnitParser.new
    all_tests, failing_tests = parser.parse(xml)

    all_tests.size.should eq(3)
    all_tests.should contain("Nightmare::CLI > --help flag prints banner")
    all_tests.should contain("Nightmare::CLI > --headless flag disables spinner")
    all_tests.should contain("Nightmare::Context > prunes completed turns")

    failing_tests.size.should eq(1)
    failing_tests.should contain("Nightmare::CLI > --headless flag disables spinner")
  end

  it "enforces test-set monotonicity: fails gate if tests disappeared without authorization" do
    engine = Nightmare::Plan::VerificationEngine.new
    baseline = Nightmare::Plan::BaselineState.new(
      total_tests: 3,
      known_failing_tests: [] of String,
      all_test_descriptions: [
        "Suite > test 1",
        "Suite > test 2",
        "Suite > test 3",
      ]
    )

    # Subagent deleted test 2! Output only has test 1 and test 3
    xml_tampered = <<-XML
    <testsuite name="Suite" tests="2" failures="0">
      <testcase classname="Suite" name="test 1" />
      <testcase classname="Suite" name="test 3" />
    </testsuite>
    XML

    with_temp_dir do |temp_dir|
      reports_dir = File.join(temp_dir, "reports")
      Dir.mkdir_p(reports_dir)
      File.write(File.join(reports_dir, "spec.xml"), xml_tampered)

      config = Nightmare::Plan::VerificationConfig.new(
        kind: Nightmare::Plan::VerificationKind::Command,
        command: ["true", "--junit_output", reports_dir],
        parser: "junit",
        expect: "no_new_failures",
        allows_test_removal: false
      )

      res = engine.evaluate_gate(config, baseline, temp_dir, temp_dir)
      res.passed.should be_false
      res.summary.should contain("monotonicity violation")
      res.disappeared_tests.should eq(["Suite > test 2"])
    end
  end

  it "passes differential gate when pre-existing baseline failures persist but no new failures exist" do
    engine = Nightmare::Plan::VerificationEngine.new
    baseline = Nightmare::Plan::BaselineState.new(
      total_tests: 3,
      known_failing_tests: ["Suite > pre_existing_bug"],
      all_test_descriptions: [
        "Suite > test 1",
        "Suite > test 2",
        "Suite > pre_existing_bug",
      ]
    )

    xml_with_known_failure = <<-XML
    <testsuite name="Suite" tests="3" failures="1">
      <testcase classname="Suite" name="test 1" />
      <testcase classname="Suite" name="test 2" />
      <testcase classname="Suite" name="pre_existing_bug">
        <failure message="Still broken" />
      </testcase>
    </testsuite>
    XML

    with_temp_dir do |temp_dir|
      reports_dir = File.join(temp_dir, "reports")
      Dir.mkdir_p(reports_dir)
      File.write(File.join(reports_dir, "spec.xml"), xml_with_known_failure)

      config = Nightmare::Plan::VerificationConfig.new(
        kind: Nightmare::Plan::VerificationKind::Command,
        command: ["true", "--junit_output", reports_dir],
        parser: "junit",
        expect: "no_new_failures"
      )

      res = engine.evaluate_gate(config, baseline, temp_dir, temp_dir)
      res.passed.should be_true
      res.new_failures.should be_empty
    end
  end

  it "fails differential gate when a new unexpected failure is introduced" do
    engine = Nightmare::Plan::VerificationEngine.new
    baseline = Nightmare::Plan::BaselineState.new(
      total_tests: 3,
      known_failing_tests: ["Suite > pre_existing_bug"],
      all_test_descriptions: [
        "Suite > test 1",
        "Suite > test 2",
        "Suite > pre_existing_bug",
      ]
    )

    xml_with_new_failure = <<-XML
    <testsuite name="Suite" tests="3" failures="2">
      <testcase classname="Suite" name="test 1">
        <failure message="New regression introduced!" />
      </testcase>
      <testcase classname="Suite" name="test 2" />
      <testcase classname="Suite" name="pre_existing_bug">
        <failure message="Still broken" />
      </testcase>
    </testsuite>
    XML

    with_temp_dir do |temp_dir|
      reports_dir = File.join(temp_dir, "reports")
      Dir.mkdir_p(reports_dir)
      File.write(File.join(reports_dir, "spec.xml"), xml_with_new_failure)

      config = Nightmare::Plan::VerificationConfig.new(
        kind: Nightmare::Plan::VerificationKind::Command,
        command: ["true", "--junit_output", reports_dir],
        parser: "junit",
        expect: "no_new_failures"
      )

      res = engine.evaluate_gate(config, baseline, temp_dir, temp_dir)
      res.passed.should be_false
      res.new_failures.should eq(["Suite > test 1"])
    end
  end
end
