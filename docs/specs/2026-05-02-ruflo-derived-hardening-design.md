# Ruflo-derived hardening — design spec

**Date:** 2026-05-02
**Status:** approved (brainstorm)
**Branch:** feat/v1.0-redesign (or successor)

## Background

Research on `ruvnet/ruflo` (a 32-plugin Claude Code marketplace for swarm orchestration) surfaced six adoptable patterns. After auditing our codebase against them:

- **PreCompact hot-tier reload** — likely redundant. `hooks/hooks.json` already wires `SessionStart` to fire on the `compact` source-event (`"matcher": "startup|resume|clear|compact"`), and `scripts/session-load.sh` re-emits the hot tier on every SessionStart. The drift gap may already be closed.
- **`allowed-tools:` skill frontmatter** — already on all 8 SKILL.md files.
- **`argument-hint:` skill frontmatter** — already on the 2 skills that take args (`query`, `doubt`).
- **`verify.sh` runtime smoke check** — not yet in codebase. Genuine additive value.

The remaining work is small and disciplined: prove the SessionStart-compact behavior so future contributors don't propose a redundant PreCompact reload, codify the `allowed-tools` convention in the validator, and add a runtime smoke check that complements the existing static validator.

Auto-extraction patterns from ruflo (SONA, ReasoningBank, post-edit `update-memory true` hooks) are explicitly **not** adopted — they conflict with v1.0's explicit-write-only philosophy.

## Goals

1. Prove `SessionStart` re-emits the hot tier after compaction. Document the proof so the redundant-PreCompact-reload pattern stays rejected.
2. Make `allowed-tools` frontmatter mandatory in `validate-plugin.sh`. Universal convention today; should fail loud if a future skill omits it.
3. Add a runtime smoke check (`scripts/verify.sh`) that complements the static `validate-plugin.sh` with live state assertions: USER.md exists, hot-tier line cap respected, MCP build artifact present, error-log clean.

## Non-goals

- No PreCompact emit changes. Existing predicate-flag behavior in `scripts/pre-compact.sh` stays untouched.
- No new skill creation. `verify.sh` is a script, surfaced through enhanced `/second-brain:status` output (not a new skill).
- No `argument-hint` additions. Only 2 skills take args today; both have it.
- No retention namespacing or doctor-fix patterns from ruflo. Deferred to v1.1+ if ever.

## Scope

### Item 1 — `tests/test-session-load-compact.sh`

A regression test that asserts the SessionStart-on-compact contract.

- Sandbox under `mktemp` per existing test convention. Set `HOME=$tmpdir`.
- Seed `~/.second-brain/USER.md` with a sentinel string (e.g. `"SENTINEL_USER_LINE"`).
- Seed `~/.second-brain/projects/<slug>/PROJECT.md` with a different sentinel.
- Invoke `bash scripts/session-load.sh` with stdin payload simulating SessionStart `source: "compact"`.
- Assert stdout contains both sentinels.
- Assert baseline file `.session-baseline-<slug>.md` was captured (so the Stop predicate has its input).
- Exit non-zero with `sb_log_error`-style message on any assertion failure.

The test does **not** depend on Claude Code itself wiring SessionStart-compact correctly — it depends only on `session-load.sh` accepting the compact-event payload shape. The harness contract (matcher firing) is verified by the `matcher` string in `hooks/hooks.json` plus the Claude Code documentation.

If this test passes, the rationale is documented inline in `hooks/hooks.json` as a one-line comment near the matcher: `// SessionStart on "compact" re-emits hot tier; PreCompact reload is therefore redundant — see tests/test-session-load-compact.sh.`

### Item 2 — `validate-plugin.sh` enforces `allowed-tools`

Extend the existing skill-frontmatter validation (lines 88-102) to fail when any `skills/*/SKILL.md` is missing `allowed-tools:` in its YAML frontmatter.

- Reuse the existing parsing pattern: `sed -n '/^---$/,/^---$/p' | sed '1d;$d'` to extract frontmatter, then `grep -q "^<field>:"` per field.
- Add `allowed-tools` to the existing `for field in name description; do` loop → `for field in name description allowed-tools; do`.
- Error format follows the existing convention: `echo "FAIL: <skill-dir>/SKILL.md missing '<field>' in frontmatter"`, increments the `ERRORS` counter, surfaces in the trailing `TOTAL: N error(s) found` line. No `sb_log_error` — the validator is a CLI tool, not a hook script, and uses its own error pattern.

This is fail-loud codification of an existing convention — adopting in this PR locks it in before drift can occur.

### Item 3 — `scripts/verify.sh` runtime smoke check

A standalone script, sourceable from `lib.sh`, that performs runtime assertions (vs. the static structural checks in `validate-plugin.sh`).

Checks performed (each fails loud via `sb_log_error`, accumulates failures, exits non-zero if any failed):

1. `~/.second-brain/USER.md` exists and is non-empty.
2. Active project's `~/.second-brain/projects/<slug>/PROJECT.md` exists (when run inside a git repo).
3. Combined hot-tier line count ≤ `LINE_CAP` (66, matching `session-load.sh`).
4. `mcp/dist/server.js` exists (so MCP tools can run).
5. `~/.second-brain/error-log.jsonl` either does not exist or has no entries newer than the last successful verify timestamp (stored at `~/.second-brain/.last-verify`).

Output format on success: a single `verify: ok` line, no narrative. On failure: one line per failed check, each prefixed `verify: FAIL: <check> — <detail>`.

`.last-verify` schema: a single line, ISO-8601 UTC timestamp (e.g. `2026-05-02T18:30:00Z`). Written on every successful run.

Surfaced through `/second-brain:status`: the existing skill grows a final section that runs `bash scripts/verify.sh` and prints its output verbatim. No new skill, no new slash command.

`verify.sh` does **not** auto-fix. It only reports. The user runs `/second-brain:setup` or other targeted skills to remediate. This matches our explicit-write philosophy.

### Item 4 — Tests for items 2 and 3

- `tests/test-validate-plugin-allowed-tools.sh` — sandboxed copy of `skills/`, mutates one SKILL.md to drop `allowed-tools:`, asserts `validate-plugin.sh` exits non-zero with the expected message.
- `tests/test-verify.sh` — sandboxed `$HOME`, exercises each failure mode of `verify.sh` (missing USER.md → fail; oversize hot tier → fail; missing dist → fail; recent error-log entry → fail; clean state → ok).

Both tests use the existing `mktemp` + `HOME=$tmpdir` pattern from `tests/test-stop-hook-predicate.sh` for consistency.

## Architecture and data flow

No new persistent state besides `.last-verify`. No new MCP tools. No hook changes. The diff is:

```
docs/specs/2026-05-02-ruflo-derived-hardening-design.md   (new — this file)
hooks/hooks.json                                          (1-line comment near matcher)
scripts/validate-plugin.sh                                (1 added assertion)
scripts/verify.sh                                         (new)
skills/status/SKILL.md                                    (final-section addition)
tests/test-session-load-compact.sh                        (new)
tests/test-validate-plugin-allowed-tools.sh               (new)
tests/test-verify.sh                                      (new)
```

`verify.sh` sources `lib.sh` for `sb_log_error`, `sb_require_jq`, and `BRAIN_DIR`. No new lib helpers needed — existing surface is sufficient.

## Error handling

Each item uses the error pattern appropriate to its caller:
- `verify.sh` is a hook-adjacent script invoked from a skill — it sources `lib.sh` and uses `sb_log_error` for any error that should be persisted to `~/.second-brain/error-log.jsonl`. Stdout output (the per-check `verify: FAIL: ...` lines) is the user-facing channel.
- `validate-plugin.sh` is a CLI validator — it uses the existing `echo "FAIL: ..."` + `ERRORS` counter pattern. Not changed by this work.
- Tests use non-zero exit codes and a clear failure message on stdout/stderr.
- No `2>/dev/null` silent fallbacks anywhere.

`verify.sh` accumulates failures rather than short-circuiting on the first — gives the user a complete picture of what's wrong in one run.

## Testing

TDD per project convention. Each item ships with at least one regression test:

- Item 1: `test-session-load-compact.sh` *is* the test. The verification is the deliverable.
- Item 2: `test-validate-plugin-allowed-tools.sh` proves the new validator rule fires.
- Item 3: `test-verify.sh` covers all five `verify.sh` failure modes plus the clean-state path.

`bash scripts/validate-plugin.sh` must continue to pass on the repo at every commit.

## Migration

None. No state schema changes. `.last-verify` is created lazily by `verify.sh` on first run; absence is treated as "no prior verify recorded" and is not a failure. No row added to the `skills/upgrade/SKILL.md` migrations table.

## Risks and open questions

- **Risk:** `validate-plugin.sh`'s frontmatter parser may not currently extract `allowed-tools` cleanly. Mitigation: read the script first; if parsing is fragile, harden it before adding the assertion. If hardening exceeds S-effort, descope item 2 to a follow-up.
- **Risk:** `verify.sh` check #5 (error-log staleness) requires a `.last-verify` timestamp file. First run after install will see *every* historical error. Mitigation: on first run, `verify.sh` writes the timestamp without flagging existing entries; subsequent runs flag only newer entries. Document this clearly in the script header.
- **Decision (resolved):** `/second-brain:status` invokes `verify.sh` automatically (not behind a flag). The skill is interactive and the verify checks are cheap (file existence + line count). If verify becomes expensive in v1.1+, revisit.

## Success criteria

- `tests/test-session-load-compact.sh` passes locally.
- `tests/test-validate-plugin-allowed-tools.sh` passes locally.
- `tests/test-verify.sh` passes locally with all five failure modes plus clean-state.
- `bash scripts/validate-plugin.sh` passes on the repo.
- `/second-brain:status` output ends with a `verify: ok` line on a clean install.
- `hooks/hooks.json` carries a one-line comment that closes the door on redundant PreCompact reload work.
