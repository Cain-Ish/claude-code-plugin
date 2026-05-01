---
name: upgrade
description: Detect installed plugin version vs the version in plugin.json, run idempotent migrations between them, and update the installed-version marker. Safe to run anytime — no-op when already at current version. Use after pulling a new plugin release or when CHANGELOG mentions schema changes.
user-invocable: true
disable-model-invocation: false
allowed-tools: Read Write Edit Bash(cat *) Bash(jq *) Bash(test *) Bash(date *) Bash(grep *) Bash(awk *) Bash(cp *) Bash(mv *) Bash(mkdir *)
---

# Plugin Upgrade

Idempotent migration runner. Reads the canonical version from `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`, compares to `~/.second-brain/.installed-version`, and applies only the migrations between them.

## Steps

### 1. Read both versions

```bash
CURRENT=$(jq -r '.version' "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json")
INSTALLED=$(cat ~/.second-brain/.installed-version 2>/dev/null || echo "0.0.0")
echo "Installed: $INSTALLED -> Current: $CURRENT"
```

### 2. Decide what to do

- If `$INSTALLED == $CURRENT` -> exit "already up to date"
- If `$INSTALLED < $CURRENT` -> walk migrations between them
- If `$INSTALLED > $CURRENT` -> exit with warning ("installed version is newer than plugin.json — did you downgrade?"). Offer to overwrite the marker.

### 3. Migration registry

Each migration is identified by its target version. Run only migrations whose target is `> $INSTALLED AND <= $CURRENT`.

| To version | Migration | Idempotent check |
|---|---|---|
| **0.4.0** | Critic-log file is created on first write — nothing to migrate. Drift-log file ditto. | No precondition. |
| **0.5.0** | learnings.md entries gain `<!-- meta: confidence=X hits=Y last_used=Z -->` lines on next /improve write. Old entries without meta line are kept. (Note: decay tracking and `decay-learnings.sh` were removed in 1.0.0 — the meta lines in pre-1.0 `learnings.md` are no longer parsed but cause no harm if present, and 1.0.0 resets `learnings.md` to header-only anyway.) No bulk rewrite required. | `grep -c "^<!-- meta: " ~/.second-brain/learnings.md` — if 0, just record the version. |
| **0.5.0** | Wiki source pages gain `Coverage:` and `Freshness tier:` fields on next /ingest. Old pages without them skip lint freshness checks. | No bulk migration. |
| **0.5.0** | `~/.second-brain/regressions/` directory created (empty) so `/second-brain:regress` finds it. | `mkdir -p ~/.second-brain/regressions` |
| **0.7.0** | New wiki directories: `patterns/`, `issues/`, `decisions/`. Graph layer deprecated (compile-graph.sh is now a no-op). Reflection gating on friction/positive signals — trivial sessions no longer queue reflections. | `KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"; mkdir -p "$KNOWLEDGE_DIR"/wiki/{patterns,issues,decisions}` |
| **0.7.0 retro-fix** | Purge pre-0.7.0 stale entries from `~/.second-brain/.pending-reflections.jsonl`. The 0.7.0 gate (`extract-learnings.sh:23`) blocks `friction_count==0 AND positive_signals==0 AND priority!="high"`, but entries queued by older code don't satisfy the gate and become permanent dead weight. Move (don't delete) them and their orphan `.reflection-context/` snapshots to `~/.second-brain/.0.7.0-purge-backup/<ISO-timestamp>/`. Discovered via `/second-brain:doubt --layer learning` 2026-05-01: 5 stale entries from session b2baa1fd (2026-04-29) plus 1 orphan snapshot. | If `test -f ~/.second-brain/.0.7.0-purge-completed`, skip. Otherwise: `mkdir -p ~/.second-brain/.0.7.0-purge-backup/$(date -u +%Y%m%dT%H%M%SZ)`, scan pending-reflections.jsonl for entries matching the dead-weight predicate (use `jq` to filter `friction_count==0 and positive_signals==0 and (priority!="high")`), move matching JSONL lines + their `context_snapshot` files to backup dir, then scan `.reflection-context/` for snapshot files with no JSONL match (orphans) and move those too. After successful run: `touch ~/.second-brain/.0.7.0-purge-completed`. Requires user confirmation if `auto_improve=false` in config.json. |
| **1.0.0** | Wipe reflection runtime (`.pending-reflections.jsonl`, `.reflection-context/`, `.learnings-hot.md`, `.compact-count`, `friction-log.jsonl`, `drift-log.jsonl`, `error-log.jsonl`, `critic-log.jsonl`, `doubt-history.jsonl`). Backup all to `~/.second-brain/.0.7.0-backup/<ISO>/`. Reset `learnings.md` to header-only. Condense `persona.md` (90 lines) → USER.md (≤15 lines) interactively. Scaffold first PROJECT.md from current repo. Keep curated wiki pages untouched. | If `cat ~/.second-brain/.installed-version` returns `1.0.0`, no-op. Otherwise run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/migrate-to-1.0.0.sh`. |

### 4. Apply migrations

For each applicable migration:
1. State what it will do
2. Run the idempotent check
3. If safe, apply it (with backup if it touches user data)
4. Report success/failure

### 5. Update marker

```bash
echo "$CURRENT" > ~/.second-brain/.installed-version
echo "Upgraded $INSTALLED -> $CURRENT"
```

### 6. Re-run validation

After migrations, re-run the plugin validator if available:
```bash
test -x "${CLAUDE_PLUGIN_ROOT}/scripts/validate-plugin.sh" \
  && bash "${CLAUDE_PLUGIN_ROOT}/scripts/validate-plugin.sh"
```

## Notes

- Migrations are intentionally minimal: most schema changes in this plugin are *additive* (new optional fields), so old data continues to work.
- Never delete or rewrite user data without explicit confirmation. The migration table is "what changed and how" — execution stays cautious.
- If a migration would be destructive, gate it behind `auto_improve: true` in `~/.second-brain/config.json` or explicit user confirmation.
- Future major versions (1.0.0+) may require interactive migrations. This skill is the place to add them.
