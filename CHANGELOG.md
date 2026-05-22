# Changelog

This file lists the user-visible changes per release. Format: each entry is one
line, past tense, optionally linking to a wiki page or PR. Entries marked
**[verified]** were confirmed by `make release-check` on the tag commit;
**[unverified]** means the gate didn't pass or wasn't run (legacy releases). New
versions starting at v2.11.0 require the verified mark — that's the whole point
of the release gate.

## v2.11.1 — bin/sb exec bit (2026-05-22) [verified]

### Fixed
- `bin/sb` and `bin/sb.cmd` were stored in git as 0644, so the documented `ln -s bin/sb ~/.local/bin/sb` install path produced a non-executable symlink — and every plugin cache refresh stripped the exec bit. Now stored as 0755 via `git update-index --chmod=+x`. Found by running `sb auth status` against a freshly-installed v2.11.0 cache after `/second-brain:upgrade` — exactly the kind of silent-install-degradation the new verification gate exists to surface.

## v2.11.0 — dual-auth + verification gate (2026-05-22) [verified]

### Added
- `sb auth status` / `sb auth doctor` CLI subcommands. One-line "which auth mode am I in?" + a guided picker.
- SessionStart auth-mode banner (`scripts/session-load.sh`). Always shows api-key / subscription / none in one line, suppressible via `SB_AUTH_LINE=off`.
- `tests/run-all.sh` aggregate test runner (shell + vitest in one go).
- `.githooks/pre-push` gate. `make hook-install` wires it in via `core.hooksPath`. Bypass: `SB_SKIP_PREPUSH=1`.
- `Makefile` with `test`, `test-quiet`, `hook-install`, `hook-uninstall`, `release-check`.
- `RELEASING.md` documenting the release checklist and bypass policy.
- New regression tests: `test-lib-extractor-backend.sh`, `test-upgrade-vector-deps.sh`, `test-session-load-auth-banner.sh`.

### Fixed
- **Recursive-claude hang.** Stop/PreCompact extraction inside Claude Code under OAuth-only auth no longer burns the 40s timeout per cycle. New `CLAUDECODE`-aware short-circuit in `scripts/lib.sh:sb_call_extractor`:
  - In-session + `ANTHROPIC_API_KEY` set → skip Backend 1 (claude CLI) entirely, go straight to direct curl.
  - In-session + OAuth only → record `status=queued` and exit non-fatal; banner surfaces the configuration.
  Escape hatch: `SB_FORCE_CLI=1` forces the legacy path (debugging only).
- **Upgrade-time vector-deps install.** `/second-brain:upgrade` now smoke-imports `@huggingface/transformers` and runs `bin/install-vector-deps.sh` when missing. Closes the gap that left fresh installs with degraded vector search.
- **Stale `test-persona-context.sh` Test 8** updated to match the v2.10 contract (persona always re-injects; wiki/episodic dedup when unchanged). The old assertion was written under v2.9 behavior and had been failing silently since.
- **`test-stop-extract.sh`** now `unset CLAUDECODE` at the top, isolating it from the test author's local Claude Code session.

### Migration notes
- The `/second-brain:upgrade` skill picks up two new rows (the 2.9.0–2.10.3 catch-up bundle + the always-on vector-deps health step). Both are no-ops on installs that are already healthy.
- No data-layout change. Existing `~/.second-brain/` and `~/knowledge/` directories are untouched.

### What this release is *not*
- Not a fix for the in-session OAuth extraction itself — that's structurally impossible inside Claude Code (recursive-claude OAuth lock). Subscription-only users either set `ANTHROPIC_API_KEY` (preferred) or accept that real-time extraction queues. An out-of-band extraction runner is on the design board but not in this release.

## v2.10.3 — episodic index empty-embedding repair (2026-05-22) [unverified]

- Episodic index: repair empty-embedding entries on indexer run; new tests.

## v2.10.2 — lint + auto-generated-orphan filter (2026-05-22) [unverified]

- Lint regex: handle period+uppercase boundary.
- Wiki validator: filter auto-generated orphans from the broken-link report.

## v2.10.1 — persona structure, wiki slugs, GC, rules-gap banner (2026-05-22) [unverified]

- Persona structure cleanups, wiki slug-only enforcement, hash-suppress bug fix, GC tightening, rules-gap banner.

## v2.10.0 — HarnessAudit Layer 1 (2026-05-21) [unverified]

- Tool-scope guard, flow-guard, SAR summary.

## v2.9.0 — HarnessAudit Layer 3 (2026-05-20) [unverified]

- Resource-scope guard, injection scanner, audit log, role-scoping.

---

Earlier versions: see `skills/upgrade/SKILL.md` migration table for the
authoritative per-version change log going back to v0.4.0. Pre-v2.11.0 tags
ship "as-is" — they were the working state on the author's machine at tag
time, but no automated gate confirmed that working state. v2.11.0 is the
first release where the version number is a verified claim.
