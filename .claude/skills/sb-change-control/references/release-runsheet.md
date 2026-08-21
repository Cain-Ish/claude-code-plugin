# Release runsheet — copy-paste sequence for cutting a release

Companion to [../SKILL.md](../SKILL.md) §3-§4. Run from repo root, in git-bash on Windows or any
POSIX shell on Linux/macOS. Every step's expected outcome is stated; stop on the first deviation.
Authored 2026-07-05 at 0.33.31 (uncommitted working tree) — re-verify the gates line against the
latest release commit body if this file is old.

## 0. Preconditions

```bash
git fetch origin main          # tripwire compares against origin/main
git status --short             # know exactly what you are shipping
npm ci --prefix mcp            # lockfile-exact deps; REQUIRED or bundle gates silently SKIP
```

## 1. Stamp the lockstep set (one logical change)

```bash
# 1a. plugin.json: bump "version" (strictly greater than origin/main's; semver-numeric)
# 1b. marketplace.json: bump the second-brain entry's "version" to the SAME value
#     (single entry since cost-router was removed in 0.35.x)
# 1c. Write the release record INTO THE COMMIT BODY (CHANGELOG.md was removed in 0.34.0 —
#     do not recreate it): "release: X.Y.Z — thesis" subject, evidence-dense bullets,
#     gates line. Pre-1.0 history: `git show archive/docs:CHANGELOG.md`.
# 1d. If counts grew: bump .claude-plugin/surface-budget.json + add a "Surface budget: X n->m" bullet.
# 1e. If a real user action exists: add skills/upgrade/migrations/X.Y.Z.md
#     (skills/upgrade/SKILL.md must stay <= 8192 bytes).
# 1f. If any mcp/src file changed: rebuild bundles and stage mcp/dist/**
cd mcp && npm run bundle && cd ..
# 1g. README.md must match what ships (new verbs/knobs/defaults documented).
```

## 2. Run the full local gate set (all must pass)

```bash
cd mcp && npx tsc --noEmit && cd ..                                    # 1 typecheck
cd mcp && SECOND_BRAIN_DISABLE_EMBEDDINGS=1 HF_HUB_OFFLINE=1 \
  TRANSFORMERS_OFFLINE=1 npm test && cd ..                             # 2 vitest offline (CI-faithful)
bash tests/test-bundle-current.sh                                      # 3 dist == rebuild of src (byte-compare)
SB_RUN_ALL_VITEST=0 bash tests/run-all.sh                              # 4 shell suite -> "ALL GREEN", exit 0
bash scripts/validate-plugin.sh                                        # 5 -> "OK: all plugin files valid"
bash tests/test-release-version-bump.sh                                # 6 -> PASS (version strictly bumped)
bash tests/test-script-portability.sh                                  # 7 static bash-3.2/BSD guards
```

Optional but recommended when vector deps are installed locally:

```bash
make release-check    # vector-deps import smoke + full run-all in one go
```

If gate 4 lists anything under `skipped:` — that is legal (capability-gated subtests), but a
FAILED section or exit 1 blocks the release. Interpretation of SKIP/FAIL semantics: see
sb-validation-and-qa.

## 3. Commit

```bash
git add -A   # review the staged set: it must contain plugin.json + marketplace.json +
             # CHANGELOG.md (+ dist bundles + surface-budget.json + migration file as applicable)
git commit -m "release: X.Y.Z — <thesis>

<bullets mirroring the CHANGELOG entry: failure mode closed, files, env defaults,
which test regression-locks each fix. Note what adversarial review caught.>

Gates green locally: tsc, vitest (<N> pass, offline), bundle-current, run-all bash
suite, validate-plugin, release version-bump tripwire, portability static guards.

Co-Authored-By: Claude <your actual model> <noreply@anthropic.com>"
```

## 4. Push and confirm server-side

```bash
git push                       # .githooks/pre-push re-runs the suite (if make hook-install was run)
# Then: confirm the "ci" GitHub workflow is green (linux + macos jobs).
#   gh run list --workflow=ci --branch=main --limit=1   # GitHub CLI, if installed
#   gh run watch                                        # or watch it finish live
# No gh on the box (true of the dev box's git-bash)? Use the repo's Actions tab.
# Windows has NO CI lane — your local Windows run WAS the Windows gate;
# the server-side run IS the Linux/BSD gate. Both are required evidence.
```

No git tag is created (tag contract: releases bind to the merge/push; nothing tagged since
v0.22.1). The release record = the version-locked manifest pair + the CHANGELOG entry + green CI.

## Abort criteria (do not ship)

- Any gate red, and the fix is not a one-liner you can land in the same batch.
- The staged diff touches shipped surface not described by the CHANGELOG entry.
- validate-plugin FAILs on surface budget and you cannot justify the growth in the
  CHANGELOG bullet (fold the new file into an existing one instead).
- You are reaching for `SB_SKIP_PREPUSH=1` for the second time in a row — per RELEASING.md,
  "the gate is wrong, not your work. Open an issue, fix the test, then resume."
