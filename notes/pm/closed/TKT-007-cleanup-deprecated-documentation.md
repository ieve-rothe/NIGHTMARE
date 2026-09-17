---
ID: TKT-007
Title: Deprecate and Consolidate Documentation in docs/
Status: Closed
Priority: Med
---

## 1. User Need
Developers and operators navigating the `nightmare` codebase need clear, authoritative, and non-redundant documentation. Obsolete architectural drafts, superseded CONOPS notes, and completed feature RFCs create ambiguity about current system behavior and invariants, cluttering the repository with duplicate information already preserved in Git history.

## 2. Specification
1. Remove obsolete files from `nightmare/docs/`:
   - `docs/ARCHITECTURE.md` (superseded Revision 2 draft)
   - `docs/DESIGN.md` (superseded by User's Guide and modern architecture doc)
   - `docs/IMPLEMENTATION_FINDINGS.md` (historical milestone retrospective)
   - `docs/PROPOSAL_SUBAGENTS_AND_DETERMINISTIC_ORCHESTRATION.md` (completed RFC for TKT-004)
2. Promote `docs/ARCHITECTURE_R3.md` to canonical `docs/ARCHITECTURE.md`:
   - Move/rename `ARCHITECTURE_R3.md` to `ARCHITECTURE.md`.
   - Update its intro header to refer to `USERS_GUIDE.md` / `docs/guide/` rather than the deleted `DESIGN.md`.
3. Update all code and specification citations across `nightmare`:
   - `src/nightmare/tools/guard.cr` (`ARCHITECTURE_R3 §4.1` -> `ARCHITECTURE §4.1`)
   - `src/nightmare/tools/shell.cr` (`ARCHITECTURE_R3 §4.3` -> `ARCHITECTURE §4.3`)
   - `spec/token_calibrator_spec.cr` (`ARCHITECTURE_R3 §7` -> `ARCHITECTURE §7`)
   - `spec/spec_helper.cr` (`ARCHITECTURE_R3 §9` -> `ARCHITECTURE §9`)
   - `notes/pm/TKT-005-integration-testing-restructure-and-core-workflows.md`
   - `notes/pm/TKT-004-subagent-plan-orchestration.md`
4. Confirm test suite passes and directory structure conforms to clean target state:
   - `nightmare/docs/` contains only `ARCHITECTURE.md` and `guide/`.

## 3. Verification & Validation (V&V)
* **Verification Plan:**
  - Verify that `nightmare/docs/` contains only `ARCHITECTURE.md` and `guide/`.
  - Check that no broken links or orphaned references to deleted files remain.
  - Run `crystal spec` to ensure all specs compile and pass cleanly.
* **Verification Evidence:**
  - `nightmare/docs/` inspected; contains only `ARCHITECTURE.md` (canonical) and `guide/` (13 chapters).
  - Workspace-wide grep for `ARCHITECTURE_R3`, `DESIGN.md`, `IMPLEMENTATION_FINDINGS`, and `PROPOSAL_SUBAGENTS` confirmed zero unresolved references in active source, specs, or tickets.
  - `crystal spec`: 214 examples, 0 failures, 0 errors, 0 pending.
  - `shards build`: binary compiled cleanly with no warnings or errors.
* **Validation Plan:**
  - Inspect repository layout to ensure documentation is clean, modern, and aligned with user expectations.
* **Validation Evidence:**
  - Layout is streamlined: canonical architecture in `docs/ARCHITECTURE.md`, user and operator guides in `docs/guide/*` with entrypoint in `USERS_GUIDE.md`.
  - Obsolete and superseded documentation safely removed, with full historical preservation in Git history.

## Open Questions & Concurrency Concerns
* None. All historical context remains accessible via Git history.

## 4. Revision History
* 2026-09-17: Ticket created, obsolete documentation removed, ARCHITECTURE_R3 promoted to ARCHITECTURE.md, citations updated, test suite verified (214/214 passing), ticket closed.
---
