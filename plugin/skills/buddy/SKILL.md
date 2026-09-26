---
name: buddy
description: The second-brain buddy — Kapi, the animated statusline capybara between Claude and the knowledge base, both ways. It shows when memory is delivered, read, or saved, which gate is holding, and what Claude says to the user through buddy_react. This skill is its on-demand side — ask the knowledge base directly (`ask`), explain the last gate (`why`), list what waits on you (`pending`), show the card, rename or mute it, install/remove its statusline. Read-only except the explicit name/mute/install verbs.
user-invocable: true
disable-model-invocation: true
allowed-tools: Read Bash(node ${CLAUDE_PLUGIN_ROOT}/mcp/dist/cli/sb-entry.bundle.js*) Bash(jq *) Bash(tail *) Bash(cat *) Bash(test *) Bash(ls *) Bash(head *) Bash(printf *) Bash(wc *) Bash(grep *) Bash(tr *)
---

# Buddy

The buddy is the visible layer between Claude and second brain (design:
`docs/plans/2026-09-22-buddy-companion.md`). Rules-based, zero tokens on the statusline: every line
is memory delivered, read (MCP `knowledge_*`/`episodic_*` calls), saved (`pin_*`, `archive_to_wiki`,
extraction), a gate holding, or something waiting on the user. This skill is the on-demand side:
the same state, plus direct questions to the knowledge base, plus the few things a user can set.

It is two-way once installed (install is the consent — `buddy.json` `react: true`) and in sessions
whose statusline renders: each prompt, `persona-context.sh` hands Claude a `[buddy: <name>]` line
(the session id, what extraction filed since its last turn, its own last line — framed as untrusted
data) and Claude ends the turn with the `buddy_react` MCP tool — that line lands in the bubble as
"Claude: …". Cost: ~80 tokens a prompt and one extra tool call a turn; `SB_BUDDY_REACT=off` drops it. The buddy is one capybara,
drawn and animated like the native `/buddy` (three frames, the 15-step idle cycle with a blink,
excited for 10 s after a new line). No account roll, no rarity, no stats: it is a memory layer.

## Argument parsing

- *(none)* — the card: name, mute state, and the last 5 buddy lines.
- `ask <question>` — answer from the knowledge base without an LLM call: BM25 over the wiki
  (`sb query`) plus past-session recall (`sb recall`), top hits with paths. Say when nothing matches.
- `why` — explain the most recent **gate** line in full: which rule fired, the audit row behind it,
  and what makes the retry pass.
- `pending` — everything waiting on the user: dreams awaiting review, held untrusted pages,
  persona rule candidates, the critic offer.
- `name <x>` — rename (1–14 chars). `mute` / `unmute` — silence the bubble (telemetry stays).
- `install` / `uninstall` — add or remove the buddy `statusLine` in the user's settings.json.
  **Ask before running `install`**: it edits `~/.claude/settings.json` (a backup is written and any
  existing statusline is chained as line 1, but the user should still say yes).

Common paths:

```bash
BRAIN="${BRAIN_DIR:-$HOME/.second-brain}"
SB="node ${CLAUDE_PLUGIN_ROOT}/mcp/dist/cli/sb-entry.bundle.js"
SID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"   # newest log is the fallback below
```

## Steps

### ask

```bash
$SB query "<question>"      # wiki pages: path, score, snippet
$SB recall "<question>"     # past sessions (transcripts) that touched it
```

Present the top 3–5 hits with their paths and one-line snippets, then offer to open one with
`knowledge_fetch(slug, tier:"gist")`. Do not paraphrase the KB into an answer the hits don't
support; "nothing in memory about X" is a valid answer.

### card (default)

```bash
$SB buddy
# last 5 buddy lines of this session (newest last); fall back to the newest log when SID is unset
LOG="$BRAIN/.buddy/${SID}.log.jsonl"
[ -n "$SID" ] && [ -f "$LOG" ] || LOG=$(ls -t "$BRAIN"/.buddy/*.log.jsonl 2>/dev/null | head -1)
[ -f "$LOG" ] && tail -n 5 "$LOG" | jq -r '"\(.ts | todate | .[11:16])  \(.kind | ascii_upcase | .[0:9])  \(.line)"'
```

Print the card as-is, then the lines. `SAID` rows are Claude's own `buddy_react` lines.

### why

```bash
LOG="$BRAIN/.buddy/${SID}.log.jsonl"
[ -n "$SID" ] && [ -f "$LOG" ] || LOG=$(ls -t "$BRAIN"/.buddy/*.log.jsonl 2>/dev/null | head -1)
GATE=$(jq -sc 'map(select(.kind=="gate")) | last // empty' "$LOG" 2>/dev/null)
[ -n "$GATE" ] || { echo "No gate has fired this session."; exit 0; }
echo "$GATE" | jq -r '"\(.source): \(.line)"'
# the audit row(s) behind it: same session, rule name matches the source's gate family
jq -c --arg sid "$SID" 'select(.session_id==$sid) | select(.rule | test("^gate-"))' "$BRAIN/audit-log.jsonl" 2>/dev/null | tail -n 3
```

Then explain in plain words, from the rule name (the `_global` log holds MCP-side events; gates
are always in the session log):

| rule | what it means | what makes the retry pass |
|---|---|---|
| `gate-a-plan-first` | 2+ distinct code files edited with no plan on record | state goal, files in scope, verify command — the retry passes and records the plan |
| `gate-b-drift-warn` / `gate-b-drift-deny` | consecutive edits share no keyword with the frozen goal | say the scope changed (merged into scope on retry) or return to the goal |
| `gate-c-verify-block` | Stop with code changed and no test/lint run | run the verify command (tests, lint) before claiming done |

Kill switches, only if the user asks: `SB_INTENT_SPINE=off` (A/B/C), `SB_PLAN_FIRST_NUDGE=off` (A/B).

### pending

```bash
# dreams completed but not yet accepted/discarded
for sf in "$BRAIN"/dreams/*/status.json; do [ -f "$sf" ] || continue
  jq -r 'select(.status=="completed" and (.archived_at // "")=="") | "dream awaiting review: \(.id)  (+\(.outputs.pages_added // 0) pages, ~\(.outputs.pages_modified // 0))"' "$sf"; done
# held untrusted pages
test -d "$BRAIN/held-untrusted" && printf 'held untrusted pages: %s\n' "$(ls -1 "$BRAIN"/held-untrusted/*/*.md 2>/dev/null | wc -l | tr -d ' ')"
# persona rule candidates (auto-arm at 3 sightings): user layer + per-repo layers (0.52.0+)
for pf in "$BRAIN/persona-rules.pending.json" "$BRAIN"/projects/*/rules.pending.json; do [ -f "$pf" ] || continue
  jq -r 'to_entries[] | "rule candidate: \(.key) (\(.value.count // .value) sightings)"' "$pf" 2>/dev/null; done
# critic offer this session
test -f "$BRAIN/.critic-offer-$SID" && echo "critic offer open: run persona_think on the diff for a fresh-context critique"
```

Say "nothing pending" when all four are empty. Next actions: `/second-brain:dream` to review a
dream; `ls ~/.second-brain/held-untrusted/` for held pages.

### name / mute / unmute / install / uninstall

```bash
$SB buddy name "<x>"      # or: $SB buddy mute | unmute | install | uninstall
```

After `install`, tell the user to restart Claude Code; after `uninstall`, that the previous
statusline (if any) was restored.
