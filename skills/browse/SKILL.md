---
name: browse
description: Browse and visualize knowledge base content. Shows wiki pages organized by category with titles and summaries. Can open the knowledge directory in Finder or list content for Obsidian browsing.
user-invocable: true
disable-model-invocation: false
allowed-tools: Read Bash(find *) Bash(cat *) Bash(ls *) Bash(head *) Bash(wc *) Bash(grep *) Bash(open *) Bash(tail *)
argument-hint: "[category]"
---

# Browse Knowledge Base

Show a visual overview of all knowledge base content.

## Steps

### 1. Overview

Show page counts per category:

```bash
echo ""
for dir in sources entities concepts synthesis sessions learnings; do
  count=$(find ${user_config.knowledge_dir}/wiki/$dir -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
  echo "  $dir/  ($count pages)"
done
echo ""
echo "Raw sources: $(find ${user_config.knowledge_dir}/raw -type f 2>/dev/null | wc -l | tr -d ' ')"
```

### 2. List Pages by Category

If `$ARGUMENTS` specifies a category (sources, entities, concepts, synthesis, sessions, learnings), only show that category. Otherwise show all.

For each wiki page found, read the first two lines to get the title and summary:

```bash
for f in $(find ${user_config.knowledge_dir}/wiki/ -name '*.md' -type f 2>/dev/null | sort); do
  category=$(echo "$f" | sed "s|.*/wiki/||" | cut -d'/' -f1)
  title=$(head -1 "$f" | sed 's/^# //')
  summary=$(sed -n '3p' "$f" | head -c 120)
  echo "[$category] $(basename "$f" .md): $title"
  if [ -n "$summary" ]; then
    echo "  $summary"
  fi
done
```

### 3. Recent Activity

Show the last 5 log entries:

```bash
tail -15 ${user_config.knowledge_dir}/log.md
```

### 4. Present as Dashboard

Format the output cleanly:

```
# Knowledge Base

## Sources (X pages)
- page-name: Title — summary

## Entities (X pages)
- page-name: Title — summary

## Concepts (X pages)
- page-name: Title — summary

## Synthesis (X pages)
- page-name: Title — summary

## Sessions (X pages)
- page-name: Title — summary

## Learnings (X pages)
- page-name: Title — summary

---
Last activity: [from log.md]
```

### 5. Offer Navigation

If the knowledge base is empty, suggest:
- `/second-brain:ingest <path>` to add a source
- `/second-brain:setup` to verify the directory structure

If pages exist, offer:
- Read any specific page by name
- Open in Finder: `open ${user_config.knowledge_dir}`
- Open as Obsidian vault (local only, no sync)
