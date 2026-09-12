Solid skeleton — the stochastic/deterministic boundary matrix and turn-unit pruning are the right instincts. But there are a few things I'd fix *before* the swarm resumes, because they're load-bearing and expensive to retrofit. Roughly in priority order:

## 1. `Turn` loses information the API needs back

`Turn` stores `user_message`, a flat list of `(call, result)` pairs, and one final `assistant_message`. To rebuild the request you have to *synthesize* the intermediate assistant messages that carried the `tool_calls`. That throws away:

- **Grouping** — two calls in one assistant message vs. two sequential messages is a different history; some providers reject the resynthesized version.
- **Interleaved assistant text** ("Let me check the config first…") alongside tool calls.
- **Provider-native reasoning blocks** — Anthropic requires thinking blocks (with signatures) to be echoed back verbatim when continuing tool use within a turn. Your design "accumulates the reasoning log separately," which will 400 on that path.

Fix: make `Turn` hold the *exact ordered* `Array(Mantle::Message)` sequence and treat `ToolExchange` as a view/index into it that mutates the tool message in place when shedding. Same pruning semantics, zero reconstruction.

## 2. Shell execution: argv vs. shell is undefined, and regex allowlists don't hold

The spec never says whether `run_command` goes through `sh -c` or `execve` with argv. This decides everything:

- If **argv**, the metacharacter ban is about honest UX (pipes won't work), not security — and the list is a fine heuristic.
- If **shell**, the ban is incomplete (`()`, `{}`, `\`, quotes, `*`) and the regex allowlist on the raw string is trivially escaped: `git -c core.sshCommand=... `, `git --exec-path=`, `find -exec`, `xargs`, `env`, `python -c`, `FOO=$(...) cmd`.

Recommend: **argv only**, allowlist matches on tokenized `argv[0]` + subcommand, plus a denylist of flag patterns (`-c`, `-e`, `--exec*`) regardless of allowlist. Also:

- Crystal's `Process` has no process-group option. You'll need `LibC.setpgid` post-fork or wrap in `setsid -w`. Flag this so an agent doesn't quietly drop the pgid requirement.
- SIGTERM → grace → SIGKILL, not straight SIGKILL.
- Cap and concurrently drain stdout/stderr (pipe deadlock on chatty commands otherwise).
- Add `PAGER=cat GIT_PAGER=cat NO_COLOR=1 TERM=dumb` to the env.

## 3. Path guard gaps

- `File.realpath` fails on nonexistent paths — `write_file` for a new file needs `realpath(dirname)` + join.
- Check `starts_with?(root + "/")`, not `starts_with?(root)` (`/home/x/proj` vs `/home/x/proj-evil`).
- **The local system prompt file lives inside `@root` and is writable by the model.** That's persistent prompt injection. Add a protected-paths set (system prompt file, `.git/`, `.nightmare*`) that mutation tools refuse.
- `PinnedFile#read_content`: `if s = @slice_start, e = @slice_end` isn't valid Crystal, and the slice will raise on out-of-range. Also needs the same root guard as tools.

## 4. Missing `StepErrorKind`s

`Cancelled` (Ctrl+C is a first-class outcome, not a `ClientFailure`) and `ContextOverflow`. The provider's `context_length_exceeded` 400 should be caught, trigger an emergency shed/prune, and retry — not bubble up as a generic client failure. That's the one place the shedder is *reactive* rather than predictive, and it's your safety net when the estimator's wrong.

## 5. Shedding trigger is wrong-shaped

"Is Tool Result > token_hardmax × 0.85" checks one result in isolation. A result that large should have been capped at the tool boundary (`read_file`/`search` return a hard-truncated output with an offset/limit hint). The shedder should fire on **cumulative estimated context**, and you have a better anchor than the EMA: the last response's `usage.prompt_tokens` is the *exact* size of everything except the new delta. Estimate only the delta.

Also add tool-call loop detection (same tool + same args N times) → forced failure message. Every agent harness eventually needs it.

## 6. Ctrl+C in raw mode isn't a signal

Salamander raw mode means 0x03 arrives as a keystroke, not SIGINT. Cancellation has to be cooperative: a `Channel` the stream fiber selects on, plus whatever abort Mantle exposes (verify it exposes one). Also, rolling back the turn doesn't roll back side effects — files were written. Inject a note into the next user message: `[Previous turn interrupted after modifying: a.cr, b.cr]` or the model will be confused about disk state.

## 7. Persist the transcript incrementally

It's in-memory only; a crash loses it. Append to `$XDG_STATE_HOME/.../transcript.md` as turns commit; `/save` becomes a copy. Trivial, and makes debugging the swarm's own output possible.

## 8. Smaller

- `Manifest` as a `struct` with `property` — mutations on copies will silently no-op. Make it a class.
- Sanitize `slug` (spaces, unicode, `/` in odd mount names).
- Pinned files re-read every turn will bust prefix caching whenever the model edits one. Consider placing the pinned block *after* history rather than before, or accept the cost consciously.
- Define the iteration cap and a per-turn spend cap.

## 9. Give the swarm tests as the contract

Nothing in the spec says how correctness is verified. Before resuming, write the invariant tests as coordination points: a fake `Mantle::Client`; "no orphaned `tool_calls` after any prune sequence"; path-guard fuzz; allowlist bypass corpus; shed → rebuild → byte-identical request for unchanged history. Autonomous agents converge much faster on red tests than on prose.
