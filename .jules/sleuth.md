# Sleuth's QA Journal - Critical Learnings

This journal documents critical, high-impact QA and testing discoveries specific to this codebase.

## 2026-10-26 - Testable CLI Runner and I/O Mocking Pattern
Discovery: `Nightmare::CLI.run` directly called `exit(0)`, `exit(1)`, `puts`, and `STDERR.puts`. In Crystal, calling `exit` from within a spec terminates the entire test suite process, leaving CLI exit status, help banner output, version reporting, invalid options, and argument validation completely untested in-memory.
Action: Decouple CLI runners by splitting `run` (which simply invokes `exit execute(...)`) and `execute(args, stdin, stdout, stderr, &block) : Int32`. Inject `IO::Memory` in specs to assert exact exit codes, stdout, and stderr for positive and negative paths without spawning subprocesses or killing the test runner.

## 2026-10-26 - Value Types in OptionParser Closures Drop Option Mutations
Discovery: Defining CLI options as a `struct Options` causes `build(options)` helper functions to pass options by value. OptionParser closures then mutate a copied value rather than the caller's instance, silently dropping parsed flags and causing fallback to default option state.
Action: Always declare CLI options containers as `class Options` when configuring `OptionParser` across helper methods to preserve reference identity across block closures.
