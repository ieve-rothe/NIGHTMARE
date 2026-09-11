# NIGHTMARE: System Design & Concept of Operations (CONOPS)

**NIGHTMARE** is a standalone, human-in-the-loop developer REPL built on the [Mantle](https://github.com/ieve-rothe/mantle) and [Salamander](https://github.com/ieve-rothe/salamander) frameworks — a general-purpose text and task execution agent that lives in plain text files and shell scripts, delegating generation and reasoning to a local Ollama model.

No character personas, no homeostatic drives, no background schedulers, no topic frame shifting, no hidden prompt injections.

> **Scope of this document.** CONOPS, tenets, requirements, and MVP boundary — *what* and *why*.
> Implementation detail — type contracts, algorithms, pipelines, constants, security mechanisms, test contract — lives in [`ARCHITECTURE.md`](ARCHITECTURE.md) and is **not** duplicated here.
> Where the two disagree, `ARCHITECTURE.md` wins on mechanism; this document wins on intent.
> Revised 2026-09-11 alongside ARCHITECTURE.md Revision 2.

---

## 1. Concept of Operations

```
                       +-------------------------------------------------+
                       |                 NIGHTMARE REPL                  |
                       |          (Workspace Root: Dir.current)          |
                       +-----------------------+-------------------------+
                                               |
        +--------------------------------------+--------------------------------------+
        |                                      |                                      |
        v                                      v                                      v
+-------------------+                +-------------------+                  +-------------------+
| Central XDG Config|                | Ephemeral Window  |                  | Pinned Files      |
| $XDG_CONFIG_HOME/ |                | - Turn-unit FIFO  |                  | - User-only /add  |
| nightmare/ws/<id>/|                | - In-turn shedding|                  | - Live re-read    |
| - prompt.md       |                | - Protected user  |                  | - :raw, :lines    |
| - allow list      |                | - Self-calibrating|                  | - /drop to unpin  |
| (Zero repo litter)|                |   ~token meter    |                  | - Cache awareness |
+-------------------+                +-------------------+                  +-------------------+
        |                                      |                                      |
        +--------------------------------------+--------------------------------------+
                                               |
                                               v
                        +-----------------------------------------------+
                        |             SALAMANDER UI LAYER               |
                        | - Startup banner: Workspace -> XDG paths      |
                        | - Live token streaming & spinner teardown     |
                        | - Hidden <think> block accumulation           |
                        | - Ctrl+C turn rollback (session preserved)    |
                        | - Commands (/clear, /cls, /save, /prompt...)  |
                        | - Multi-line paste mode (""" or /paste)       |
                        +----------------------+------------------------+
                                               |
                                               v
                        +-----------------------------------------------+
                        |            MANTLE EXECUTION ENGINE            |
                        | - Mantle::Step + on_iteration projection hook |
                        | - Typed Result sum type at every LLM boundary |
                        | - Rate limit auto-retry with backoff          |
                        | - Read-only tools (zero approval needed)      |
                        | - Mutation tools (diff + approval to overwrite|
                        |   existing; .git/ and .nightmare/ forbidden)  |
                        | - Stateless sub-query delegation: ask_model   |
                        | - run_command: argv only, approval modal,     |
                        |   metacharacter ban, process group kill       |
                        +----------------------+------------------------+
                                               |
                                               v
                        +-----------------------------------------------+
                        |        CENTRAL CANONICAL PERSISTENCE          |
                        | - Pristine transcript, incrementally written  |
                        | - Workspace logs isolated under XDG_STATE_HOME|
                        | - Zero files written into target repo         |
                        +-----------------------------------------------+
```

## 2. Core Tenets

1. **Workspace-bound root.** Anchored to `Dir.current`, canonicalized once at boot. Every tool operation is confined within it; traversal and out-of-tree symlinks are rejected.
2. **Zero repository litter.** No config, state, cache, or log file is ever written into the target repo. Everything persistent lives in XDG directories, partitioned per workspace.
3. **Ephemeral by default, pristine on demand.** Conversational state is RAM-resident and evaporates on exit. A parallel un-pruned transcript is kept so `/save` writes a complete record with no truncation stubs.
4. **Turn-unit pruning and in-turn shedding.** Pruning operates on atomic turn units. Within a running turn, older *consumed* tool outputs are compressed so a long tool loop cannot exhaust the window mid-task. The user's instruction is never touched.
5. **Honest observability.** Raw exchanges are logged centrally. Token meters self-calibrate against provider usage and are always shown with a tilde (`~2,160t`) because they are estimates.
6. **Rigorous security, anti-fatigue approval.** Read-only tools run silently. Mutations auto-approve new files but require a diff and consent to overwrite. Shell execution is argv-only with explicit approval controls and a hard ban on auto-approving metacharacters. **Approval fatigue is a security failure**: a user who reflexively types `y` has no boundary at all, so the design spends its approval budget only where consequences are real.
7. **The human is the supervisor, not the operator.** The agent proposes and executes; the human retains a veto at every irreversible step and can interrupt any turn without losing the session.

---

## 3. Requirements

Authoritative statement of requirements. `.agents/ORIGINAL_REQUEST.md` holds the original user phrasing and acceptance criteria.

**R1 — Workspace anchoring and central XDG mapping.** Anchor to the realpath of `Dir.current`; prevent all operations outside it. Persist config, state, and cache in central XDG directories keyed by a deterministic per-workspace identifier. Never write inside the target repo. Print a startup banner showing root, config, and state paths. Resolve system directives in strict precedence: CLI flag → repo override → workspace config → global config → default persona.

**R2 — Ephemeral context engine, turn-unit pruning, in-turn shedding.** Keep context in memory as an atomic turn-unit sliding window. Pruning must never orphan a tool pair and never evict the active turn's user prompt. When approaching token limits during multi-step tool iterations, compress older consumed tool results within the active turn while preserving the most recent verbatim. Self-calibrate token estimation from provider usage feedback. Maintain a parallel un-pruned transcript for `/save`.

**R3 — Sandboxed tool suite and anti-fatigue approval boundary.** Read-only observation tools run autonomously, excluding `.git/` and sensitive files. Mutation tools auto-approve new file creation but require a unified diff and approval to modify existing files; writes to `.git/` are forbidden. Provide stateless model delegation. Provide shell execution with process group isolation, a hard timeout cap, closed stdin, and an interactive approval modal, with a strict ban on auto-approving any command containing shell metacharacters.

**R4 — Mantle step harness and typed result sum types.** Orchestrate execution via Mantle's step runner. Encapsulate every LLM interaction in a typed success/failure sum type. Apply exponential backoff with jitter on rate limits. Trigger a single format-correction retry on malformed payloads before returning a typed error.

**R5 — Interactive Salamander REPL and slash command router.** Terminal REPL with live token streaming, spinner management, `<think>` isolation, and ANSI markdown formatting. `Ctrl+C` during generation cancels and rolls back the active turn without terminating the session. Support the commands in §5.

**R6 — Framework integration constraints.** Link `mantle` and `salamander` by local path. Minor backward-compatible enhancements to either are permitted where strictly necessary; major structural refactoring is prohibited.

### R2 addendum — why in-turn shedding exists

Recorded here because it is a requirement rationale, not a mechanism. Every iteration of a tool loop re-sends the entire accumulated buffer, so context grows *within* one turn: a build failure plus three file reads plus a grep can exhaust a small window by iteration six, with no conversation history involved at all. Turn-unit pruning cannot help — there are no completed turns to evict. And a tool result cannot simply be dropped, because it must stay paired with its originating tool call. Shedding is the only remaining move: keep the message, shrink its content, leave the model's active working set intact.

This matters at the scale NIGHTMARE targets. Against a frontier model's context window it would rarely trigger; against the 8k–32k local models Mantle's client speaks to, it is load-bearing. Mechanism, thresholds, and the framework change it requires are in `ARCHITECTURE.md` §2.1 and Pipeline 3.

---

## 4. Operator-Visible Behaviour

What a user actually sees. Mechanisms behind each are in `ARCHITECTURE.md`.

**Startup.** A bordered banner reporting workspace root, config path, and state path — so it is always obvious which workspace is active and that nothing is being written into the repo.

**Directives.** The active system prompt resolves by precedence and is reported on request. `/prompt edit` opens `$EDITOR` and changes the directive **in memory only**; no file on disk is modified. Directive files inside the repo are readable but never writable by the agent.

**Working memory meter.** Displays calibrated estimates with a tilde, plus turn count and pinned-file cost. Estimates are labelled as estimates because they are.

**Pinned files vs. reading files.** `read_file` is the agent's transient observation tool — a snapshot subject to shedding and eviction. `/add` is the user's working set: pinned above history, re-read live from disk every turn, persisting until `/drop`. If the agent tries to `read_file` something already pinned, it is told so instead of paying for the content twice. Pinning is budget-capped, and `/add` fails loudly rather than silently degrading context.

**Approvals.** Read-only tools never prompt. Creating a new file never prompts. Overwriting an existing file shows a unified diff and asks. Shell commands show the command, cwd, and timeout, and offer: run once, refuse, edit first, always allow this exact command, or always allow this prefix. Anything containing shell metacharacters always prompts regardless of prior allowances.

**Interruption.** `Ctrl+C` during a turn cancels it and rolls the turn back; the session survives and the typed input is returned for editing. Because rollback cannot undo files already written or commands already run, the next message states plainly what was modified before the interrupt. Exiting requires `/exit`, `Ctrl+D`, or two rapid `Ctrl+C` at an empty prompt.

**Transparency.** `/review` shows the exact prompt assembly currently being dispatched. `/thinking` shows the last hidden reasoning block. `/save` exports the pristine transcript. Raw exchanges are logged centrally unless `--no-log`.

---

## 5. Command Reference

| Command | Effect |
| :--- | :--- |
| `/add <path> [--lines S-E]` | Pin a file (or line range) into the live working set |
| `/drop [path]` | Unpin one file, or all if omitted |
| `/clear` | Wipe the conversational window; pinned files and directive survive |
| `/cls` | Clear the physical terminal screen |
| `/save [path]` | Export the pristine, un-pruned transcript as Markdown |
| `/prompt [edit]` | Show the active directive; `edit` opens `$EDITOR`, in memory only |
| `/review` | Show the exact prompt assembly currently dispatched to the model |
| `/thinking` | Show the hidden reasoning block from the last turn |
| `/model [name]` | Show or switch the active Ollama model |
| `/paste` (or `"""`) | Toggle multi-line input mode |
| `/help` | Command syntax and keybindings |
| `/exit` | End the session; ephemeral state evaporates |

---

## 6. MVP Boundary

### In scope for v1

1. **Core runtime and XDG mapping** — canonical root, per-workspace XDG partitioning, startup banner, directive precedence.
2. **Context engine** — turn-unit pruning, in-turn shedding, self-calibrating token meter. No long-term memory store.
3. **Pristine transcript** — parallel un-pruned history, exported via `/save`, durable against a crash.
4. **Read-only tools** — `list_files`, `search`, `read_file`, `file_info`; autonomous, root-contained, sensitive patterns excluded.
5. **Mutation tools** — `replace_in_file`, `append_to_file`, `write_file`; root-contained, protected paths enforced, diff-and-approve on overwrite.
6. **Shell execution** — `run_command`, argv-only, process group isolation, timeout cap, closed stdin, approval modal.
7. **Model delegation** — `ask_model`, a stateless sub-query that does not contaminate turn history.
8. **Pinned files** — `/add` with raw and line-range slices, live re-read, redundancy short-circuit, `/drop`.
9. **Salamander UI** — streaming, spinner teardown, `<think>` isolation, `Ctrl+C` turn rollback, ANSI markdown.
10. **Commands** — as listed in §5.
11. **Audit log** — per-workspace JSONL under `$XDG_STATE_HOME`, rotated, disableable.

### Explicitly deferred to v2

- Fast-model summarization preprocessor (`/add --summary`).
- Pre-approved scripts directory.
- Multi-agent swarm coordination.
- Additional model providers. **v1 targets Ollama local inference only**, and provider-native reasoning-block echo is out of scope with it (`ARCHITECTURE.md` D2).
- Raw-mode single-keypress approval modals; v1 approvals are line input (`ARCHITECTURE.md` D3).

---

## 7. Known Constraints

Consequences of the framework stack, carried here so scope conversations start from the truth. Evidence in `ARCHITECTURE.md` §2.

- **In-turn shedding requires a Mantle change.** `Mantle::Step` runs its tool loop over a private buffer, so the caller cannot observe or reshape it mid-turn. Resolved by an additive per-iteration projection hook — `mantle` TKT-008 — which R6 permits. Shedding and faithful turn capture are blocked until it lands.
- **Ollama local inference only.** One concrete Mantle client, one provider. This is a scope decision, not a limitation to work around — it is also what makes the context budget small enough for in-turn shedding to matter.
- **The terminal is line-buffered.** Salamander has no raw mode, so approval input is a letter plus Enter rather than a single keypress. `Ctrl+C` does deliver a real signal, but cancellation is still cooperative.
- **Streaming cannot be aborted mid-flight.** Cancellation takes effect on the next chunk or between iterations; a stalled stream waits for its timeout.
- **Rollback is not undo.** Interrupting a turn discards its context, not its side effects on disk.
