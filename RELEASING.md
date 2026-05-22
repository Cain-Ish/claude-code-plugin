# Releasing

This document is the binding release checklist for the `second-brain` plugin.
Versions get tagged only when every box below is checked. Anything short of
that produces a "shipped pending verification" build — useful for testing on
your own machine, not for tagging or pushing to others.

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
      That covers shell tests + Vitest. Currently 24 shell + 59 vitest = 83
      checks. A regression in any one blocks the release.
- [ ] **Vector deps importable.** `cd mcp && node --input-type=module -e \
      'await import("@huggingface/transformers")'` exits 0. The upgrade
      skill installs this automatically, but verify before tagging because
      a successful tag implies a working install.
- [ ] **Bundle is current.** `cd mcp && npm run bundle` produces the same
      `dist/cli/sb-entry.bundle.js` and friends already committed. (If diff
      shows changes, the source was edited but the bundle was not rebuilt —
      commit the bundle update too.)
- [ ] **`skills/upgrade/SKILL.md` migration table has a row for `vX.Y.Z`.**
      The row says what changed and how to detect already-migrated state.
      No row → upgraders will silently end up in an inconsistent state.
- [ ] **`README.md` matches what ships.** New CLI verbs, new config knobs,
      changed defaults — all documented. README is the user's first contact
      with the plugin; it can't lag the code.
- [ ] **`CHANGELOG.md`** updated with a section for `vX.Y.Z`. Each item one
      line, in past tense, with the wiki/PR link if any. List both fixes and
      additions — and if anything is *known broken*, list it explicitly here.
      Honest changelog > inflated changelog.
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
breakage from the user; "minor bump + CHANGELOG row + upgrade-skill row"
makes the change visible at install time.
