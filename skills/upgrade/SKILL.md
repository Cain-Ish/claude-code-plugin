---
name: upgrade
description: Detect installed plugin version vs the version in plugin.json, run idempotent migrations between them, and update the installed-version marker. Safe to run anytime — no-op when already at current version. Use after pulling a new plugin release.
user-invocable: true
disable-model-invocation: true
allowed-tools: Read Write Edit Bash(cat *) Bash(jq *) Bash(test *) Bash(date *) Bash(grep *) Bash(awk *) Bash(ls *) Bash(cp *) Bash(mv *) Bash(mkdir *) Bash(node *) Bash(cd *) Bash(bash *)
---

# Plugin Upgrade

Idempotent migration runner. Reads the canonical version from
`${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`, compares to
`~/.second-brain/.installed-version`, and applies only the migrations between
them. Migration ACTIONS live in `skills/upgrade/migrations/<version>.md` —
one file per release that has a real precondition or action. A version with
NO file is marker-bump-only (its narrative is in the repo CHANGELOG.md, which
is never context-loaded). This split keeps a typical 1–2 version hop under
~2K tokens instead of loading the full release history (R6, deep-dive).

## Steps

### 1. Read both versions

```bash
CURRENT=$(jq -r '.version' "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json")
INSTALLED=$(cat ~/.second-brain/.installed-version 2>/dev/null || echo "0.0.0")
echo "Installed: $INSTALLED -> Current: $CURRENT"
```

### 2. Decide what to do

- If `$INSTALLED == $CURRENT` -> exit "already up to date"
- If `$INSTALLED < $CURRENT` -> walk migrations between them (step 3)
- If `$INSTALLED > $CURRENT` -> exit with warning ("installed version is newer
  than plugin.json — did you downgrade?"). Offer to overwrite the marker.

### 3. Select applicable migration files

List `${CLAUDE_PLUGIN_ROOT}/skills/upgrade/migrations/` and Read ONLY the
files whose `<version>.md` name satisfies `> $INSTALLED AND <= $CURRENT`
(semver-style comparison, e.g. via `sort -V`):

```bash
ls "${CLAUDE_PLUGIN_ROOT}/skills/upgrade/migrations/" | sort -V
```

Versions in range with no file need nothing beyond the marker bump.

> Re-baselined to 0.11.1 (2026-05-24): `INSTALLED` is always ≥ 0.11.1, so no
> pre-0.11 migrations can fire. If the version ever re-crosses 1.0.0, write
> fresh forward migrations — do not resurrect pruned history from git.

### 4. Apply migrations

For each applicable migration file, in version order:
1. State what it will do
2. Run its idempotent check
3. If safe, apply it (with backup if it touches user data)
4. Report success/failure

### 5. Update marker

```bash
echo "$CURRENT" > ~/.second-brain/.installed-version
echo "Upgraded $INSTALLED -> $CURRENT"
```

### 6. Re-run validation

```bash
test -x "${CLAUDE_PLUGIN_ROOT}/scripts/validate-plugin.sh" \
  && bash "${CLAUDE_PLUGIN_ROOT}/scripts/validate-plugin.sh"
```

## Notes

- Migrations are intentionally minimal: most schema changes in this plugin are
  *additive* (new optional fields), so old data continues to work.
- Never delete or rewrite user data without explicit confirmation. A migration
  file is "what changed and how" — execution stays cautious.
- If a migration would be destructive, gate it behind explicit user
  confirmation.
- RELEASE POLICY (R6): a `migrations/<version>.md` file is added ONLY when a
  release has a real precondition or action; every release adds a CHANGELOG.md
  entry. The validator caps this SKILL.md at 8KB so it cannot regrow into a
  context-loaded changelog.
