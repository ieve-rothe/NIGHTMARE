# PROGRESS

## 2026-10-03 — Compiled NIGHTMARE 0.5.0 release
- Task: "compile next harness release" (for kicks).
- In-flight work was TKT-027 (globally readable dirs) + TKT-028 (globally writable dirs), both marked Resolved in notes/pm/.
- Implemented TKT-029: Adaptive directory listing depth and result budget limiting in `list_files`.
- `shards build --release` → clean. `bin/nightmare` = 5.6MB.
- `crystal spec` → 319 examples, 0 failures, 0 errors, 0 pending.
- Bumped version 0.4.0 → 0.5.0 in: src/nightmare.cr (VERSION), shard.yml, spec/nightmare_spec.cr.
- Added CHANGELOG [0.5.0] - 2026-10-03 entry documenting TKT-027/028/029.
- `./bin/nightmare --version` → NIGHTMARE 0.5.0. ✅
