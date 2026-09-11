# ⚠ ARCHITECTURE CHANGE NOTICE — Revision 2

**Issued:** 2026-09-11 · **Author:** human + review pass · **Source of change:** `UPDATE_ARCHITECTURE.md` plus direct verification against `../mantle` and `../salamander`

`docs/ARCHITECTURE.md` has been revised while the swarm was paused. **Read §2 (Framework Reality), §8 (Configuration Constants), §9 (Invariant Test Contract), and §10 (Open Decisions) before you resume.** Sections changed in this revision are tagged `**[R2]**`.

Milestone 1 (workspace, XDG mapping, directives) is **unaffected and still gated PASS**. Everything downstream of it is affected to some degree.

---

## 🛑 Stop-and-read: one change invalidates in-flight M2 design work

**`Mantle::Step` cannot support in-turn shedding or a message-exact `Turn`.**

`Mantle::Step#run` (`../mantle/src/mantle/steps/step.cr:48`) copies its `messages` argument into a **local** `working_messages`, runs the entire tool-call loop against that local buffer, and discards it on return. The caller receives only `StepResult(String, StepError)` — final text, `thinking`, `iterations`, `raw_response`.

So:

- The buffer the in-turn shedder must rewrite **is invisible to NIGHTMARE**.
- The intermediate assistant messages (tool-call grouping, interleaved assistant text) **are destroyed**, so a `Turn` cannot be captured through `Step#run`.
- There is **no abort/cancel hook** anywhere on `Client#execute` or `Step#run`.

**Resolution (§2.1, D1) — DECIDED 2026-09-11: patch Mantle, do not duplicate the loop.**

Mantle is first-party, so the data gets surfaced rather than the loop reimplemented. `Mantle::Step` gains one additive, backward-compatible hook — tracked as **`mantle` TKT-008** (`../mantle/notes/pm/open/TKT-008-step-on-iteration-hook.md`):

```crystal
@on_iteration : Proc(Array(Mantle::Message), Mantle::Clients::Response?, Array(Mantle::Message))? = nil

# in Step#run, immediately before each client.execute:
working_messages = hook.call(working_messages, last_response) if hook = @on_iteration
```

Default `nil` → identity → no existing caller is affected. That one hook gives NIGHTMARE in-turn shedding, message-exact `Turn` capture, the `prompt_eval_count` token anchor, and per-turn spend accounting. It does **not** break the graph isolation TKT-007 established: the hook rewrites `Step`'s already-ephemeral *local* buffer, never the canonical context graph, and `messages` stays immutable input.

So `Mantle::Step` remains the execution path for the primary turn, and R4 is satisfied literally. `Nightmare::Harness::ToolLoop` is the **thin policy layer that owns the hook closure** — capture, calibrate, predictive check, shed — *not* a reimplementation of the loop. Do **not** refactor `Mantle::Step`'s existing control flow; the hook is a pure insertion.

**Residual gap, accepted:** a provider length rejection propagates out of `Step#run`, so `ContextOverflow` recovery re-runs the whole turn rather than retrying the single failed call. It is the reactive backstop, not the primary path. If it fires often in practice the follow-on is an `on_error` hook, not a NIGHTMARE-owned loop.

**Sequencing:** shedding and turn capture are **blocked on TKT-008 landing**. Everything else in M2 — `TokenEstimator`, `PinnedFiles`, `Transcript`, and the `Turn`/`ToolExchange` data models themselves — is unblocked and should proceed.

---

## Per-agent impact

### `explorer_m2_1` — Context Models, Sliding Window, In-Turn Shedding — **REDESIGN REQUIRED**

Your dispatch specified `ToolExchange` as `{call_id, name, args, output, shed}` — a standalone record — and a `Turn` of `{user message, exchanges, assistant message}`. **Both shapes are superseded.**

- `Turn` now holds `messages : Array(Mantle::Message)` — the **exact ordered wire sequence**. No synthesis on assembly; the stored array *is* the request body. §3.2.
- `ToolExchange` is a **view/index** into `Turn#messages` (`turn`, `index`, `call`, `raw_size_bytes`, `shed?`), not a standalone record.
- **`Mantle::Message` is a `struct`.** `turn.messages[i].content = x` mutates a copy and **silently does nothing**. Verified experimentally. Two safe forms, per §3.2: index write-back inside `Turn` (indices must stay stable for `ToolExchange` views), and `#map` rebuild at the Mantle hook boundary (the hook returns a new array by contract). On rebuild, pass `tool_call_id:` as a **keyword** — the third positional parameter of `Message#initialize` is `tool_calls`, and dropping the id is exactly what breaks pair integrity. Guarded by test **T3**, but the failure mode is silent in production code.
- Add to `Turn`: `prompt_tokens : Int32?`, `interrupted : Bool`, `side_effects : Array(String)`, and a `well_formed?` pair-integrity predicate asserted after every mutation and prune.
- **The shedding trigger changed.** It is no longer "is this one tool result > hardmax × 0.85". It fires on **cumulative estimated context**, anchored on `Response#prompt_eval_count` from the previous call (the exact size of everything but the new delta), with the EMA estimating only the delta. Oversized single results are now capped **at the tool boundary** instead (§4.1) — coordinate with whoever owns M3 tools.
- Shedding never removes a message, only rewrites `content`, so pair integrity holds by construction.
- New requirement: `LoopDetector` (identical `(tool, args)` × 3 in a turn → refusal tool result, no execution).

### `explorer_m2_2` — Token Calibrator & Pinned Files — **CORRECTIONS**

- **`INITIAL_DIVISOR` is `3.5`, not `4.0`.** Your dispatch brief says 4.0; `.agents/spec_miner_survey_1/specs.md` §2.5 says 3.5. The brief is wrong. §8 is now the single source of truth for every constant.
- **The usage field is `Mantle::Clients::Response#prompt_eval_count`**, not `usage.prompt_tokens`. Ollama naming. It and `eval_count` are both **nilable on every response** — never divide by nil or zero.
- The calibrator now has a second job: expose `last_prompt_tokens` as the anchor for the shedder's cumulative estimate, so the EMA only ever estimates the delta since the last call. Coordinate with `explorer_m2_1`.
- `PinnedFile#read_content` as previously specified was **uncompilable** (`if s = @slice_start, e = @slice_end` is not valid Crystal) and raised on out-of-range slices with no root guard. Corrected form in §3.3: clamp the slice, return `""` on an inverted range, and route every read through `Tools::Guard.resolve_read`.
- Clamp `[1.0, 10.0]` and `calibrator.json` in the cache dir are unchanged. 60% pinned budget unchanged.
- **D5 SETTLED: pinned block goes before history**, accepting prompt-cache invalidation when the model edits a pinned file. Correctness over cache locality. Documented in §Pipeline 2 — don't silently reorder it.

### `explorer_m2_3` — Transcript, Mantle Assembly, M2 Test Specs — **SIGNIFICANT CHANGES**

- **`assemble_mantle_messages` is no longer a conversion.** It splats `Turn#messages` in order. There is nothing to convert — the turn stores `Mantle::Message` natively. Your dispatch's "User message → [Tool call → Tool result]* → Assistant message" reconstruction is exactly the synthesis this revision removed.
- **`Transcript` is no longer in-memory-only.** It appends to `$XDG_STATE_HOME/nightmare/workspaces/<id>/transcript.md` as messages are produced, keeping an in-memory mirror for `/save` and `/review`. `/save [path]` becomes a copy. Rationale: a crash used to lose the transcript, including the crash you most want to read. §6.
- **Your test-spec deliverable is now partly pre-written.** §9 defines 19 invariants (T1–T19) as the project's coordination surface, including a `FakeClient < Mantle::Clients::Client` (scripted response queue, records every message array it received, can inject `ClientFailure` / 429 / length-rejection on the Nth call). Treat §9 as the required floor and extend it — do not author a parallel, differently-shaped suite.
- Note that `spec/e2e/test_runner.cr` already provides an HTTP-level `MockLlmServer` for the process tier. `FakeClient` is the in-process unit-level complement, not a replacement.

### Whoever picks up M3 (Tools) — **NEW REQUIREMENTS**

- **`run_command` is argv-only, never `sh -c`** (§4.2, D4). This was previously undefined, which made the whole security model unanalyzable — a regex allowlist over a raw string that is then handed to a shell is trivially escaped.
- Allowlist matches on **tokens** (`argv[0]` basename + `argv[1]` subcommand), not on the raw string.
- **A flag denylist overrides any allowlist**: `-c`, `-e`, `--exec*`, `--eval*`, `-C`, `--config`, `--upload-pack`, `--receive-pack`, and any `k=v` token before the first non-flag arg. This is what closes `git -c core.sshCommand=…` and `python -c` against a per-binary allowlist.
- The metacharacter ban **stays and is still mandatory (R3)**, but its framing changed: under argv those characters are inert, so the ban is a UX guard against silently-wrong execution plus defense in depth — not the security boundary.
- **Crystal's `Process` has no process-group option.** You must establish the pgid explicitly via `LibC.setpgid(0, 0)` post-fork or `setsid -w`. Without it `Process.kill(Signal::KILL, -pgid)` has no group and orphans survive. **Do not quietly drop this** — test **T9** asserts it.
- Termination is **SIGTERM → 2s grace → SIGKILL**, both to `-pgid`. Not straight to SIGKILL.
- **Drain stdout and stderr concurrently** into capped buffers. Sequential drain deadlocks on a chatty command (test **T10**).
- Add `PAGER=cat GIT_PAGER=cat NO_COLOR=1 TERM=dumb` to the subprocess env alongside `GIT_TERMINAL_PROMPT=0 CI=1`. Without the pager vars, `git log`/`git diff` hang forever.
- **New protected-path denylist** (`Tools::Guard`, §4.1): mutation tools refuse `.git/**` *and* `.nightmare/**` unconditionally — **refusal, not an approval modal; never approvable**. `.nightmare/prompt.md` is a Tier-2 system-directive source that lives inside `@root`; leaving it model-writable is a persistent prompt injection that survives restarts.
- **Every tool caps its own output** at `TOOL_OUTPUT_MAX_BYTES` (64 KiB) with an offset/limit continuation hint. This is now a precondition for the context engine — the shedder no longer defends against a single oversized result.

### Whoever picks up M4 (Harness) — **TYPE CONTRACT CHANGED**

- **`alias Result(T) = Success(T) | Failure` does not compile.** Crystal has no generic aliases (`Error: expecting token '=', not '('`). Verified. Replaced by a single generic `StepOutcome(T)` with a nil-discriminated payload, mirroring `Mantle::StepResult`. §3.1.
- `StepErrorKind` gains `Cancelled`, `ContextOverflow`, `ToolExecutionFailure`, `SpendCapExceeded`; `MalformedPayload` is renamed **`MalformedOutput`** to match `Mantle::StepError`.
- **`Cancelled` is not a failure.** No `Retrier`, no error log, no failure budget. It rolls back and returns to the prompt.
- **`ContextOverflow` is a recovery path, not a report.** A provider length rejection triggers an emergency shed + prune and **one** retry before surfacing. This is the safety net for estimator error, so it is not optional. Test **T11**.
- You own `ToolLoop` (see the stop-and-read above), `LoopDetector`, and `TURN_SPEND_CAP_TOKENS`.

### Everyone — **D2 SETTLED: Ollama local inference only**

v1 targets one provider. Consequences: provider-native reasoning-block echo is **not a constraint** (not merely deferred — do not build forward-compat scaffolding for it); `ask_model` is a stateless local sub-query, not a remote API call; and the small `TOKEN_HARDMAX` is deliberate, since 8k–32k local windows are exactly why in-turn shedding is load-bearing. `Turn` stays message-exact for tool-call grouping, which is provider-independent.

### Whoever picks up M5 (UI) — **PREMISE CORRECTED**

- **Salamander has no raw mode.** `Salamander::UI#ask_user` is `print prompt; gets` — cooked, line-buffered. There is no termios handling anywhere in Salamander.
- Consequence 1: `Ctrl+C` **does** deliver a real `SIGINT` here. (The review in `UPDATE_ARCHITECTURE.md` §6 assumed raw mode; that premise is inverted for this stack.) Cooperative cancellation is still required, because a Crystal signal handler runs on the signal-handling fiber and cannot unwind the streaming fiber. The handler does the minimum — channel send, set flag — and consumers poll. §Pipeline 5.
- Consequence 2: **single-keypress `[y]`/`[N]`/`[a]` modals are not available.** **D3 SETTLED: line mode.** Type the letter, press Enter; empty input is the `[N]` default. No termios work in v1. Write modal prompt text as a line prompt — do not imply a keypress the terminal will not deliver.
- Consequence 3: **Mantle exposes no stream abort.** Cancellation mid-stream works by raising from the `on_chunk` block on the next chunk; the raise propagates out of `Step#run` and `Harness::StepRunner` rescues it. (`ToolLoop`'s `on_iteration` hook also checks the cancel flag between iterations, which covers the gap between tool completion and the next inference call.) A stream that has stopped producing chunks cannot be interrupted until it times out. Document this limit rather than pretending otherwise.
- **Rollback does not undo side effects.** Files were written; commands ran. If `turn.side_effects` is non-empty, the next user message must carry `[Previous turn was interrupted after modifying: a.cr, b.cr]`, or the model reasons about a disk state that no longer matches its context. Test **T13**.
- `<think>` is stripped twice by design — `Response#initialize` for the final result, `ChatSession#process_chunk` for the live stream. Not a bug; don't "fix" it.
- `tts_kokoro` is in `shard.yml` only because `Salamander::Terminal`/`UI` require it transitively. TTS is constructed `nil` and is not a NIGHTMARE feature.

### Orchestrator — **PROCESS CHANGES**

1. **Re-dispatch the three in-flight M2 explorers**, or send each a correction message pointing at this notice and at the specific sections above. Their briefs contain superseded type shapes (`explorer_m2_1`, `explorer_m2_3`) and one wrong constant (`explorer_m2_2`: divisor 4.0 → 3.5).
2. **§8 is now the single source of truth for constants.** Quote it by reference in future dispatches instead of restating values — that is how the 3.5/4.0 divergence happened.
3. **§9 (T1–T19) is the gate contract.** Reviewers, challengers, and auditors should check work against the numbered invariants rather than re-deriving a bar per milestone. Autonomous agents converge much faster on red tests than on prose.
4. **§10: all five decisions (D1–D5) are settled as of 2026-09-11.** None is an open question for an implementing agent. D1 patch Mantle with `on_iteration`; D2 Ollama local inference only; D3 line-mode approvals; D4 argv-only shell; D5 pinned-before-history.
5. **New cross-repo dependency.** `mantle` TKT-008 must land before shedding or turn capture can be implemented. It is a ~5-line additive insertion in `Mantle::Step#run` plus a constructor property. Sequence it first, or dispatch it in parallel with the unblocked M2 work.
6. **`docs/DESIGN.md` was rewritten** to match Revision 2 and to stop duplicating it. The split is now strict: **DESIGN = CONOPS, tenets, requirements (R1–R6), operator-visible behaviour, command reference, MVP boundary, known constraints. ARCHITECTURE = type contracts, algorithms, pipelines, constants, security mechanisms, test contract.** Do not restate mechanism in DESIGN or intent in ARCHITECTURE. All implementation detail that used to live in DESIGN §§2–9 (type definitions, pruning algorithm, path-containment rules, subprocess guardrails, calibration formula) is **deleted from DESIGN**, not moved — it was already in ARCHITECTURE. Constants live in ARCHITECTURE §8 only.
6. **Test-speed work is preserved.** `Nightmare::E2E.repl_ready?` memoizes a short-timeout probe so unimplemented-milestone e2e specs report `pending!` immediately. Verified after the change: full `crystal spec` is **164 examples, 0 failures, 0 errors, 101 pending in 725 ms** (the four unit files alone: 56 examples in 74 ms). §9 requires new unit specs to keep that property — no network, no sleeps, no compiler invocations.

---

## Quick triage table

| If you were working on… | Then… |
| :--- | :--- |
| M1 workspace / directives | No action. Still gated PASS. |
| `Turn` / `ToolExchange` / `SlidingStore` | **Redesign.** §2.1, §2.2, §3.2. |
| Token calibrator | Two corrections: divisor `3.5`, field `prompt_eval_count`. §2.4, §8. |
| Pinned files | `read_content` was uncompilable; corrected in §3.3. |
| Transcript / message assembly | Assembly is a splat, not a conversion. Transcript is incremental. §6. |
| M2 test specs | Use §9 T1–T19 as the floor; add `FakeClient`. |
| Tools / shell | argv-only, token allowlist, flag denylist, pgid, SIGTERM ladder, concurrent drain, protected paths, output caps. §4. |
| Harness / result types | `StepOutcome(T)`; new error kinds; `ContextOverflow` recovery. §3.1. |
| UI / signals | No raw mode; line-mode modals; cooperative cancel; side-effect note. §2.5, Pipeline 5. |
