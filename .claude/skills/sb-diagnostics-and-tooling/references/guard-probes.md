# Guard liveness probe matrix (manual, copy-pasteable)

Full manual probe set for the three PreToolUse guards. The shipped
`scripts/guard-liveness.sh` in this skill dir automates the core subset; use this
matrix when you need a single targeted probe, want to test a kill switch both ways,
or are extending the probe set. Derived from the guards' own regression tests
(`tests/test-symlink-guard.sh`, `tests/test-persona-tool-guard.sh`,
`tests/test-wiki-write-guard.sh`) as of 0.33.31 (2026-07-05).

## Probe hygiene (read first)

1. **Verdict semantics**: empty stdout = no decision (silent allow). JSON on stdout
   with `.hookSpecificOutput.permissionDecision` = the guard fired. A guard that
   should deny but prints nothing is FAIL-OPEN — the 0.33.31 incident class.
2. **Sandbox the side channels**: guard verdicts APPEND to the real
   `$BRAIN_DIR/audit-log.jsonl`, and wiki-write-guard's tombstone branch can `mv`
   an archived page back into the wiki. Always run probes with
   `BRAIN_DIR=$(mktemp -d)`; sandbox `HOME` too when probing credential prefixes.
3. **Build JSON with `printf`, never `jq --arg`, when the payload carries POSIX
   paths**: on Windows git-bash, MSYS converts POSIX path arguments handed to the
   native `jq.exe` into `C:\` form, which silently breaks `$HOME`-prefix checks
   (house rule; `tests/test-symlink-guard.sh:28-29`).
4. **Environment honesty**: the guards honor kill switches from YOUR environment.
   If `SB_PERSONA_GATE=off` or `SB_SYMLINK_GUARD=off` is exported, a "failed" probe
   means DISABLED, not broken. Check `env | grep '^SB_'` before concluding.
5. **Prove the probe before trusting a SILENT verdict**: an unparseable payload also
   yields empty stdout — indistinguishable from fail-open. Intermediate shell/tool
   layers (Claude Code's Bash tool, ssh, make) each process backslashes once and can
   mangle the sed program inside `pay()` or any hand-typed `\\`/`\\n` payload
   (reproduced live 2026-07-05: a healthy 0.33.31 guard read as fail-open this way).
   Self-check first: `pay Write "$HOME/.ssh/x" | jq -e . >/dev/null || echo PAY-BROKEN`.
   If broken, fall back to the guards' own regression tests
   (`bash tests/test-symlink-guard.sh` etc.) — they build payloads in-process and are
   immune to layer mangling. Same trap documented at sb-debugging-playbook D1.
6. Setup used by every probe below:

```bash
P="${CLAUDE_PLUGIN_ROOT:-$PWD}"          # plugin root (repo checkout works)
PB=$(mktemp -d)                          # throwaway BRAIN_DIR — probe side effects land here
pay() {  # $1 tool  $2 file_path  -> payload on stdout (printf, not jq)
  local et ep
  et=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
  ep=$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"session_id":"probe","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"file_path":"%s"}}' "$et" "$ep"
}
dec() { jq -r '.hookSpecificOutput.permissionDecision // "SILENT"'; }
```

## 1. symlink-guard.sh (credential-dir write denial, G-HOOK-2)

Protected set (deny on write resolving into): `~/.ssh`, `~/.gnupg`, `~/.aws`,
`~/.config/claude`, `~/.config/gh`, `~/.password-store`, `~/.netrc`, `/etc`
(tests 1–6, 15–16). Kill switch `SB_SYMLINK_GUARD=off`.

| # | Probe | Expect |
|---|---|---|
| 1 | `pay Write "$HOME/.ssh/authorized_keys" \| BRAIN_DIR=$PB bash "$P/scripts/symlink-guard.sh" \| dec` | `deny` (reason mentions `ssh`) |
| 2 | same, path `$HOME/.gnupg/x` / `$HOME/.aws/credentials` / `$HOME/.config/claude/auth.json` / `$HOME/.netrc` / `/etc/sudoers.d/x` / `$HOME/.password-store/x.gpg` | `deny` each |
| 3 | `pay Write "$PWD/README.md" \| BRAIN_DIR=$PB bash "$P/scripts/symlink-guard.sh"` | EMPTY (not over-blocking) |
| 4 | `pay Write "~/.ssh/id_rsa"` (tilde form) | `deny` (guard expands `~`) |
| 5 | `pay Write "$HOME/.ssh"` (the dir NODE, no trailing slash) | `deny` (equality fallback; v0.21.0 finding) |
| 6 | `pay Bash "$HOME/.ssh/x"` | EMPTY (non-write tool ignored) |
| 7 | payload with `tool_input: {}` (no file_path) | EMPTY (no false positive) |
| 8 | symlink escape: `ln -s ~/.ssh/authorized_keys innocent.txt` then Write `innocent.txt` | `deny` — only meaningful where symlinks are real (Windows without Developer Mode makes copies) |
| 9 | Windows form (git-bash only): `pay Write "$(cygpath -w "$HOME/.ssh/id_probe")"` | `deny` — THE historical fail-open: `C:\` payload vs `/c/` prefixes, guards inert on the dev platform until 0.33.31's `sb_normalize_path` funnel |
| 10 | case-varied `...\.SSH\...` (Windows form) | `deny` (NTFS/APFS case-insensitivity bypass closed) |
| 11 | extended-length `\\?\C:\...\.ssh\...` | `deny` (normalizer strips the `//?/` prefix) |
| 12 | kill switch BOTH ways: `SB_SYMLINK_GUARD=off` + probe 1 | EMPTY (switch works); then UNSET and re-run probe 1 → `deny` |
| 13 | fail-closed: `realpath` shadowed by an `exit 127` stub on PATH + probe 1 | still `deny`; probe 3 still EMPTY (lexical fallback, no over-block) |

## 2. persona-tool-guard.sh (Layer-3 rules + resource/tool scope)

Rules come from `$BRAIN_DIR/persona-rules.json` when present, else the shipped
`scripts/persona-rules.default.json`. With a throwaway `BRAIN_DIR` you probe the
DEFAULT rules (the mechanism); point `BRAIN_DIR` at the real one to probe the user's
live rule content (then accept the audit-log append). Kill switches:
`SB_PERSONA_GATE=off` (whole guard), `SB_RESOURCE_SCOPE=off`, `SB_TOOL_SCOPE=off`;
extensions `SB_RESOURCE_SCOPE_EXTRA=/path`, `SB_TOOL_SCOPE_EXTRA="Tool1:Tool2"`.

Run each as: `echo '<payload>' | BRAIN_DIR=$PB bash "$P/scripts/persona-tool-guard.sh"`

| # | Payload | Expect |
|---|---|---|
| 1 | `{"tool_name":"Bash","tool_input":{"command":"ls foo 2>/dev/null"}}` | `allow` + `.hookSpecificOutput.updatedInput.command` WITHOUT `2>/dev/null` (strip-silent-fallback rewrite) |
| 2 | `{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}` | `ask` (warn-force-push-main) |
| 3 | `{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/foo"}}` | `ask` (warn-rm-rf) |
| 4 | `{"tool_name":"Write","tool_input":{"file_path":"/x/.second-brain/USER.md","content":"foo"}}` | `ask` (warn-direct-write-hot-tier) |
| 5 | `{"tool_name":"Edit","tool_input":{"file_path":"/home/x/claude-code-plugin/scripts/lib.sh"}}` | `ask` (self-protection: safety-layer edit) |
| 6 | `{"tool_name":"Bash","tool_input":{"command":"ls -la"}}` | EMPTY (harmless) |
| 7 | `{"tool_name":"Edit","tool_input":{"file_path":"/etc/hosts"},"cwd":"/home/u/proj"}` | `ask`, reason mentions resource scope (resource_scope is LIVE by default; allowlist = `$CWD`, `~/.second-brain`, `~/knowledge`, `/tmp`, `/var/tmp`) |
| 8 | probe 7 with `SB_RESOURCE_SCOPE=off` | EMPTY |
| 9 | probe 7 with `SB_RESOURCE_SCOPE_EXTRA="/etc"` | EMPTY (extension honored) |
| 10 | tool-scope (OPT-IN; needs `tool_scope.enabled=true` in a rules file you write into `$PB/persona-rules.json`): `{"tool_name":"WebFetch","tool_input":{"url":"https://x"},"session_id":"ts1"}` | `ask`, reason mentions tool scope |
| 11 | audit evidence after any ask/deny/rewrite: `grep '"hook":"persona-tool-guard.sh"' "$PB/audit-log.jsonl"` | ≥1 line — proves the `sb_log_audit` channel too |
| 12 | kill switch: `SB_PERSONA_GATE=off` + probe 1 | EMPTY |

## 3. wiki-write-guard.sh (frontmatter contract)

Matches any path containing the literal `/knowledge/wiki/<category>/*.md` segment
(after backslash→slash normalization), `index.md` exempt. Kill switch:
`SB_PERSONA_GATE=off` (shared). The tombstone/auto-restore branch reads
`$BRAIN_DIR/wiki-archive-log.jsonl` and CAN move archived pages — the throwaway
`BRAIN_DIR` neutralizes it.

```bash
WP="$PB/knowledge/wiki/state/probe-page.md"   # sandbox path still matches the guard's glob
# deny — no frontmatter:
printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"# no frontmatter"}}' "$WP" \
  | BRAIN_DIR=$PB bash "$P/scripts/wiki-write-guard.sh" | dec        # -> deny
# EMPTY — frontmatter present:
printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"---\\ntitle: x\\ntype: state\\n---\\n\\n# x\\n"}}' "$WP" \
  | BRAIN_DIR=$PB bash "$P/scripts/wiki-write-guard.sh"              # -> EMPTY
# EMPTY — index.md exempt; EMPTY — non-wiki .md path out of scope
```

Edit/MultiEdit variants: an Edit against a file that already starts `---` is always
allowed; against a frontmatter-less file it denies unless `new_string` (or one edit
in a MultiEdit batch) introduces `---` (tests 5–7).

## Not probed here

`flow-guard.sh` (Bash/WebFetch/WebSearch credential-egress "ask") and
`plan-first-nudge.sh` (soft advisory) are also PreToolUse-wired but outside this
skill's three-guard liveness set; their payload shapes are in
`tests/test-flow-guard.sh` and `tests/test-plan-first-nudge.sh` — same stdin-JSON
probe technique applies.

## Re-verify (this file drifts with the guards)

```bash
bash tests/test-symlink-guard.sh && bash tests/test-wiki-write-guard.sh
bash tests/test-persona-tool-guard.sh   # incl. Test 22 (lib.sh-unsourceable fallback: rules
#   supplied via a user persona-rules.json in BRAIN_DIR, since CLAUDE_PLUGIN_ROOT=/nonexistent
#   also removes persona-rules.default.json — fixed 2026-07-05, green as of 0.33.31)
jq -r '.hooks.PreToolUse[].hooks[].command' hooks/hooks.json   # wiring ground truth
```
