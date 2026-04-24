#!/bin/bash
# Silently ensure knowledge directory and learning state directories exist.
# Runs at SessionStart — must be fast and silent.

KNOWLEDGE_DIR="${CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR:-$HOME/knowledge}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR/#\~/$HOME}"

COMPANION_DIR="$HOME/.claude-companion"

# Knowledge base structure (Karpathy wiki pattern)
mkdir -p "$KNOWLEDGE_DIR/raw/assets"
mkdir -p "$KNOWLEDGE_DIR/wiki/sources"
mkdir -p "$KNOWLEDGE_DIR/wiki/entities"
mkdir -p "$KNOWLEDGE_DIR/wiki/concepts"
mkdir -p "$KNOWLEDGE_DIR/wiki/synthesis"
mkdir -p "$KNOWLEDGE_DIR/wiki/sessions"
mkdir -p "$KNOWLEDGE_DIR/.embeddings"

# Initialize index.md if missing
if [ ! -f "$KNOWLEDGE_DIR/index.md" ]; then
  cat > "$KNOWLEDGE_DIR/index.md" << 'EOF'
# Knowledge Base Index

Content catalog organized by category. Updated automatically on each ingest.

## Sources
<!-- Summaries of ingested raw sources -->

## Entities
<!-- People, organizations, products, tools -->

## Concepts
<!-- Ideas, frameworks, patterns, theories -->

## Synthesis
<!-- Cross-cutting analyses and comparisons -->

## Sessions
<!-- Insights extracted from coding sessions -->
EOF
fi

# Initialize log.md if missing
if [ ! -f "$KNOWLEDGE_DIR/log.md" ]; then
  echo "# Knowledge Base Log" > "$KNOWLEDGE_DIR/log.md"
  echo "" >> "$KNOWLEDGE_DIR/log.md"
  echo "Chronological record of ingests, queries, and maintenance." >> "$KNOWLEDGE_DIR/log.md"
fi

# Initialize schema.md if missing
if [ ! -f "$KNOWLEDGE_DIR/schema.md" ]; then
  cat > "$KNOWLEDGE_DIR/schema.md" << 'EOF'
# Wiki Schema

## Page Types

- **Source**: Summary of an ingested document. Lives in `wiki/sources/`.
- **Entity**: Person, organization, product, or tool. Lives in `wiki/entities/`.
- **Concept**: Idea, framework, pattern, or theory. Lives in `wiki/concepts/`.
- **Synthesis**: Cross-cutting analysis connecting multiple sources/entities. Lives in `wiki/synthesis/`.
- **Session**: Insight extracted from a coding session. Lives in `wiki/sessions/`.

## Conventions

- Use `[[wiki-links]]` for cross-references between pages
- Each page starts with `# Title` followed by a one-line summary
- Include `## Related` section at bottom with wiki-links to connected pages
- Date format: YYYY-MM-DD
- File naming: lowercase-kebab-case.md

## Log Format

Entries in log.md use: `## [YYYY-MM-DD] operation | Title`
Operations: ingest, query, lint, session
EOF
fi

# Learning state directory
mkdir -p "$COMPANION_DIR"

# Initialize learnings.md if missing
if [ ! -f "$COMPANION_DIR/learnings.md" ]; then
  cat > "$COMPANION_DIR/learnings.md" << 'EOF'
# Learned Patterns

Strategic principles distilled from coding sessions. Read at session start.
Each entry captures what worked, what failed, and actionable guidance.
EOF
fi

# Initialize quality-rules.md if missing
if [ ! -f "$COMPANION_DIR/quality-rules.md" ]; then
  cat > "$COMPANION_DIR/quality-rules.md" << 'EOF'
# Code Quality Rules (Auto-Evolved)

These rules are checked after every code write/edit. New rules are added
automatically when the self-improvement engine detects recurring patterns.

## Error Handling
- Handle error cases before the happy path
- Check for edge cases: empty arrays, null, undefined, 0, empty string
- Validate function return types match all code paths
- Never swallow errors silently — log or propagate

## Code Hygiene
- Verify imports exist before using them
- Don't leave TODO/FIXME without implementation
- Check for resource cleanup (close connections, clear timers, remove listeners)
- Avoid magic numbers — use named constants

## Security
- Never expose secrets in code (API keys, passwords, tokens)
- Sanitize user input at system boundaries
- Use parameterized queries, never string concatenation for SQL
- Validate URLs, file paths, and external data

## Consistency
- Follow existing project patterns and conventions
- Match the naming style used in surrounding code
- Use the same error handling strategy as the rest of the codebase
EOF
fi

# Initialize empty friction log if missing
if [ ! -f "$COMPANION_DIR/friction-log.jsonl" ]; then
  touch "$COMPANION_DIR/friction-log.jsonl"
fi

# Add a .gitignore inside knowledge dir to prevent accidental git tracking of embeddings
if [ ! -f "$KNOWLEDGE_DIR/.gitignore" ]; then
  cat > "$KNOWLEDGE_DIR/.gitignore" << 'EOF'
.embeddings/
.nosync
.DS_Store
EOF
fi

# Prevent cloud sync services from syncing knowledge and learning data.
# .nosync prevents iCloud, .donotbackup is a broader hint.
touch "$KNOWLEDGE_DIR/.nosync" 2>/dev/null
touch "$COMPANION_DIR/.nosync" 2>/dev/null

# If the knowledge dir is inside an Obsidian vault, disable Obsidian Sync
# for the .embeddings directory (binary data, not useful in Obsidian)
if [ -d "$KNOWLEDGE_DIR/.obsidian" ]; then
  mkdir -p "$KNOWLEDGE_DIR/.obsidian"
  # Write .nosync inside .embeddings to prevent sync of vector data
  touch "$KNOWLEDGE_DIR/.embeddings/.nosync" 2>/dev/null
fi

exit 0
