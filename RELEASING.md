# Releasing

This document is the binding release checklist for the `second-brain` plugin.
A version is released when every box below is checked on the merge commit.
Anything short of that produces a "shipped pending verification" build —
useful for testing on your own machine, not for pushing to others.

> **Tag contract amendment (R8, 2026-06-11; amended 2026-07-24):** the practice
> moved from git tags to marketplace-version + the release commit body as the
> release record (nothing tagged since v0.22.1, while every release since is
> fully traceable via the version-locked `plugin.json`/`marketplace.json` pair,
> its `release: X.Y.Z — …` commit body, and the merged PR). The pre-1.0
> CHANGELOG.md was removed from main in the pre-1.0 diet; it is preserved on
> the `archive/docs` branch. The gate below now binds to the MERGE, not the tag:
> every release lands via a PR with `tests/run-all.sh` green locally AND the
> `ci` workflow green server-side. Tags are optional annotations; if you do
> tag, the old rule still holds (gate green on the tagged commit).

## Why this exists

Until v2.11.0, version numbers were aspirational. Each `fix(v2.X.Y): …`
commit was hopeful, not proven. Several minor releases shipped with core
features broken (extractor, vector search, persona dedup) because there was
no test gate between "code that compiles" and "code I tagged."

v2.11.0 is the first release with a verification gate. The contract:

> **A version tag is valid ONLY when `make release-check` exits 0 on the
> commit being tagged.**

If the gate failed and you tagged anyway (via `--no-verify`, `--no-gpg-sign`,
`SB_SKIP_PREPUSH=1`, or a manual `git tag`), the version is **not real** — it
ships a known-broken state, and any user who pulls it inherits that. Use
those bypasses only when you've already opened the follow-up fix in the same
session.

## The checklist

Before tagging `vX.Y.Z`:

- [ ] **All tests green.** `make test` (or `bash tests/run-all.sh`) exits 0.
      That covers shell tests + Vitest. Read the live counts off the suite
      output and `.claude-plugin/surface-budget.json` rather than a number
      frozen here. A regression in any one blocks the release.
- [ ] **Vector deps importable.** `cd mcp && node --input-type=module -e \
      'await import("@huggingface/transformers")'` exits 0. The upgrade
      skill installs this automatically, but verify before tagging because
      a successful tag implies a working install.
- [ ] **Bundle is current.** `cd mcp && npm run bundle` produces the same
      `dist/cli/sb-entry.bundle.js` and friends already committed. (If diff
      shows changes, the source was edited but the bundle was not rebuilt —
      commit the bundle update too.)
- [ ] **The release commit body is the release record** (until 1.0): a
      `release: X.Y.Z — thesis` subject, narrative bullets, and the gates line.
      (Pre-1.0 CHANGELOG.md history lives on the `archive/docs` branch.) If the
      release has a real precondition/action, ALSO add
      `skills/upgrade/migrations/vX.Y.Z.md` (the runner loads only files in the
      upgrade hop). SKILL.md itself stays a lean runner (8KB cap, gated). No
      migration row → upgraders silently land in an inconsistent state (R6 policy).
- [ ] **`README.md` matches what ships.** New CLI verbs, new config knobs,
      changed defaults — all documented. README is the user's first contact
      with the plugin; it can't lag the code.
- [ ] **`make release-check`** exits 0. This runs both the vector-deps
      smoke and the full test suite in one go.

After tagging:

- [ ] **Pre-push hook is installed.** If you cloned freshly, run
      `make hook-install` once (sets `core.hooksPath=.githooks`). This makes
      every future `git push` re-run the suite. The gate is the persistence
      mechanism — without it the checklist erodes within weeks.

## Bypass policy

The bypasses exist because the gate must not become a load-bearing block on
an emergency hotfix. But each bypass leaves a trail:

| Bypass | When OK | When not OK |
|---|---|---|
| `SB_SKIP_PREPUSH=1 git push` | Genuinely broken test + you have a fix open in the same branch | Routinely skipping because a test is "annoying" |
| `git push --no-verify` | Same as above | Same as above |
| Manual `git tag` without `release-check` | Never. Always run the check before tagging. | Always |

If you find yourself using a bypass twice in a row on different commits, the
gate is wrong, not your work. Open an issue, fix the test, then resume.

## Version policy (informal SemVer)

Until the plugin has a paying-user surface, treat versions as:

- **major** (e.g. 3.0.0): on-disk data layout or USER-visible CLI breaks.
- **minor** (e.g. 2.11.0): new features the user can opt into; old paths still work.
- **patch** (e.g. 2.10.4): bug fixes only; no behavior change for healthy installs.

A patch release that requires user action (e.g. running a script, exporting
an env var) should be a minor. "Same patch number, different behavior" hides
breakage from the user; "minor bump + upgrade-skill row"
makes the change visible at install time.

## Local development loop

Editing the repo does **not** change the installed plugin until the cache
refreshes — this is the recurring "I edited it and nothing happened" trap
([[plugin-cache-vs-repo-gap]]). To iterate against your working tree directly,
launch Claude Code with this repo as a local plugin dir:

```bash
# Run CC with the local checkout shadowing the installed copy
claude --plugin-dir /home/cainish/Projects/claude-code-plugin
# Inside the session, after editing skills/agents/hooks:
/reload-plugins
```

- `--plugin-dir <path>` loads a **local** plugin and shadows the installed one
  — your edits are live without a cache round-trip.
- `/reload-plugins` re-reads skill/agent/hook definitions mid-session (the
  bundled MCP server may still need a fresh session to drop old DB handles).
- **Never use `--plugin-url`** for this loop. A remote zip is a
  download-and-execute path — it fails the verify-before-install rule and the
  P0 supply-chain posture. Local dir only.

## Storage location invariant (do not write state into the plugin root)

`${CLAUDE_PLUGIN_ROOT}` is **ephemeral**: Claude Code changes it on every
update and cleans the previous copy ~7 days later. It is read-only territory
for the plugin's bundled code/scripts — **never** write runtime state there.

This plugin is already correct: all durable state lives **outside** the plugin
root —

- `~/knowledge/` — wiki cold tier + the relational graph (`graph/edges.jsonl`)
- `~/.second-brain/` — USER.md, per-project PROJECT.md, transcripts, episodic
  index, persona signals, audit/error logs

If a future feature needs plugin-managed durable state, use
`${CLAUDE_PLUGIN_DATA}` (`~/.claude/plugins/data/<id>/`, survives updates) —
**not** `${CLAUDE_PLUGIN_ROOT}`. (Verified against CC 2.1.156 docs:
code.claude.com/docs/en/plugins-reference#persistent-data-directory.)
