---
name: upgrade
description: Bring an installed second-brain plugin up to date with the current release. Use after pulling a new plugin version. Safe to run anytime — idempotent, no-op when already at the current version.
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
NO file is marker-bump-only (its narrative is in the release commit body,
which is never context-loaded). This split keeps a typical 1–2 version hop under
~2K tokens instead of loading the full release history.

## Steps

### 1. Read both versions

```bash
CURRENT=$(jq -r '.version' "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json")
INSTALLED=$(cat ~/.second-brain/.installed-version 2>/dev/null || echo "0.0.0")
echo "Installed: $INSTALLED -> Current: $CURRENT"
```

### 2. Decide what to do

Compare versions SEMVER-style, never lexicographically (string compare says
`0.24.9 > 0.24.18`!) — e.g. `[ "$(printf '%s\n' "$INSTALLED" "$CURRENT" | sort -V | tail -1)" = "$CURRENT" ]`:

- If `$INSTALLED == $CURRENT` -> step 4b (health check) then exit "already up to date"
- If `$INSTALLED` semver-older than `$CURRENT` -> walk migrations between them (step 3)
- If `$INSTALLED` semver-newer than `$CURRENT` -> exit with warning ("installed
  version is newer than plugin.json — did you downgrade?"). Offer to overwrite
  the marker.

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

### 4b. vector-deps health (re-runs EVERY upgrade, not version-gated)

Smoke-import `@huggingface/transformers` from the plugin's mcp dir; on failure
run the installer. Why: the mcp bundles mark it esbuild `--external` (native
binaries), and a plugin cache refresh ships `dist/` but never `node_modules/`
— without this gate vector search silently degrades to text-only on every
fresh install or cache wipe (no error, just empty embeddings). SessionStart
auto-relinks the no-network case; this check covers the
fresh-install/download case that needs consent.

```bash
cd "$CLAUDE_PLUGIN_ROOT/mcp" && node --input-type=module -e 'await import("@huggingface/transformers"); console.log("ok")' >/dev/null 2>&1 \
  || bash "$CLAUDE_PLUGIN_ROOT/bin/install-vector-deps.sh"
```

Idempotent: the script no-ops when the import already works. Report the ~70MB
network requirement before a first-ever install.

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
  release has a real precondition or action; release narrative lives in the
  release commit body. The validator caps this SKILL.md at 8KB so it cannot
  regrow into a context-loaded changelog.
