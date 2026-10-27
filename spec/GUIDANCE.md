# Testing Guidance & Best Practices Ledger

This document serves as an ongoing ledger of testing conventions, architectural patterns, and best practices for the spec suite.

---

## 1. CLI Testing & I/O Injection (`Nightmare::CLI.execute`)

- **Never call `Nightmare::CLI.run` in specs**: `run` invokes `exit`, immediately terminating the spec runner process.
- **Always use `Nightmare::CLI.execute`**: Accepts abstract `stdin`, `stdout`, `stderr` streams (`IO::Memory.new`) and returns an `Int32` exit status code.
- **When to use `execute`**:
  - **Exit Codes**: Verify CLI command failure/success codes (`0` vs `1`).
  - **Output Formatting**: Assert exact error or banner output on `stderr` and `stdout`.
  - **Negative Flag Testing**: Test invalid flags and missing option arguments without shell subprocesses.
  - **Environment Configuration**: Pass a block `execute(args, ...) { |repl| ... }` to assert that CLI arguments (`--model`, `-R`, `-W`, `--no-log`, `--markdown`) correctly configure the `REPL` and `Workspace::Environment` without launching interactive prompts.

---

## 2. Test Isolation & Console Cleanliness

- **Zero Output Leakage**: Specs must run completely silent. When instantiating UI components (e.g., `Nightmare::UI::TurnPresenter`), always inject `output: IO::Memory.new`.
- **Order Independence**: Every spec must remain isolated and pass under `crystal spec --order=random`. Never depend on global state or execution order across files.
- **File System Cleanliness**: Use `with_temp_dir` or `Spec.after_each` to guarantee that all test files, sockets, and mock XDG directories are cleaned up immediately after execution.
