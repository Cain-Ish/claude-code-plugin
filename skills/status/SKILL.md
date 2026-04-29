---
name: status
description: Show knowledge base statistics, health overview, and recent activity. Displays page counts, category breakdown, recent ingests/queries, and quick health indicators.
user-invocable: true
disable-model-invocation: false
allowed-tools: Read Bash(find *) Bash(wc *) Bash(cat *) Bash(ls *) Bash(tail *) Bash(grep *) mcp__knowledge-base__knowledge_stats
---

# Knowledge Base Status

Show a dashboard of the knowledge base state.

## Steps

### 1. Gather Stats

If the `knowledge_stats` MCP tool is available, use it first:
```
knowledge_stats()
```

Also gather filesystem stats directly:

```bash
# Resolve knowledge dir from the env var Claude Code injects per userConfig.
# Skill-body ${user_config.X} placeholders DO NOT expand in bash — use the env var instead.
KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"

# Page counts per category
for dir in sources entities concepts synthesis sessions learnings patterns issues decisions; do
  echo "$dir: $(find "$KD/wiki/$dir" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
done

# Total size
du -sh "$KD/"

# Raw source count
find "$KD/raw" -type f 2>/dev/null | wc -l
```

### 2. Recent Activity

Show the last 10 entries from log.md:
```bash
KD="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
tail -30 "$KD/log.md"
```

### 3. Learning State

Show counts from the learning state:
```bash
# Learnings count
grep -c "^## " ~/.second-brain/learnings.md 2>/dev/null || echo "0"

# Quality rules count  
grep -c "^- " ~/.second-brain/quality-rules.md 2>/dev/null || echo "0"

# Friction signals today
grep -c "$(date +%Y-%m-%d)" ~/.second-brain/friction-log.jsonl 2>/dev/null || echo "0"

# Persona rules count
grep -c "^- " ~/.second-brain/persona.md 2>/dev/null || echo "0"

# Discovered tools
cat ~/.second-brain/tool-registry.json 2>/dev/null
```

### 3b. Error Log

```bash
if [ -f ~/.second-brain/error-log.jsonl ]; then
  CUTOFF=$(date -u -d '7 days ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-7d +"%Y-%m-%dT%H:%M:%SZ")
  RECENT=$(jq -r --arg c "$CUTOFF" 'select(.timestamp >= $c)' ~/.second-brain/error-log.jsonl 2>/dev/null | jq -s 'length')
  echo "Hook errors (7d): ${RECENT:-0}"
  if [ "${RECENT:-0}" -gt 0 ]; then
    echo "Recent errors:"
    tail -5 ~/.second-brain/error-log.jsonl | jq -r '"\(.timestamp) \(.script): \(.message)"'
  fi
else
  echo "Hook errors (7d): 0"
fi
```

### 4. Present Dashboard

Format as a clean dashboard:

```
# Knowledge Base Status

## Wiki Pages
- Sources:    X
- Entities:   X  
- Concepts:   X
- Synthesis:  X
- Sessions:   X
- Learnings:  X
- Total:      X

## Embeddings
- Indexed:    X / X pages (X% coverage)
- Last indexed: YYYY-MM-DD

## Learning State
- Learned patterns: X
- Quality rules:    X
- Persona rules:    X
- Friction signals today: X
- Available tools:  X MCP servers

## Health
- Hook errors (7d):  X
- [last 3 errors if any]

## Recent Activity
[last 5 log entries]
```
