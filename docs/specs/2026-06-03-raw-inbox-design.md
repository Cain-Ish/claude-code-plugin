# SP-2 — Raw Inbox — Design

**Status:** approved (2026-06-03)
**Vision:** consolidation roadmap — sub-project SP-2 of 6 (SP-0 Four Principles ✓, SP-1 project-scoped serving ✓).
**Scope chosen:** *Foundation + real producer.* SP-2 builds the raw-inbox structure/contract **and** a working manual producer. SP-3 (setup deep-scan, the bulk producer) and SP-4 (maintainer drain raw→nodes) are separate later sub-projects that plug into the contract defined here.

---

## Problem

Knowledge enters the KB today only as **finished** artifacts:

- the capture-time **extractor** (Stop hook) writes complete wiki pages;
- **`track`/doc-sources** references the user's *existing* local files in place (read-only registry — SP-1 local-docs), it is not a staging area;
- the **`sources`** wiki category holds finished "external reference material" provenance pages;
- **dream / maintainer** consolidate what is already in the wiki.

There is nowhere to **drop unprocessed material** — a PDF, a pasted spec, a clipped article, a future setup-scan's output — and hold it until something refines it into proper wiki nodes. That missing staging area is the **raw inbox**. It is the foundation SP-3 fills and SP-4 drains.

## Goals

1. A per-project staging area for unprocessed material, with provenance, held **out** of the searchable wiki.
2. A single, drift-free contract for the inbox's location/format/lifecycle, declared in the source of truth (`kb-schema.json`) and read by both the TS and bash sides.
3. A working **manual producer** so a human can fill the inbox end-to-end today (before SP-3/SP-4 land).
4. Lightweight **surfacing** so the user knows there is a backlog to process.

## Non-goals (explicitly deferred)

- **SP-3** setup deep-scan (the bulk auto-producer that seeds a project's inbox from a folder walk).
- **SP-4** maintainer **drain**: turning raw items into wiki nodes, auto status transitions, and projecting the raw→node edge.
- URL **auto-fetch** (offline-first: SP-2 records the URL as a pointer).
- Binary **text-extraction** (PDF/OCR). SP-2 records a one-line gist only.

---

## Architecture

```
~/.second-brain/projects/<slug>/
├── PROJECT.md                 (existing)
├── doc-sources.config.json    (existing)
├── doc-sources.json           (existing)
└── raw/                        ← NEW: this project's raw inbox
    ├── 20260603T141500Z-auth-spec.md      (sidecar manifest + body)
    ├── 20260603T141500Z-auth-spec.pdf     (original blob, when binary)
    └── 20260603T150210Z-rate-limit-note.md
```

Raw lives in the **hot tier, per project** — beside the project's other state, project-scoped by construction (consistent with SP-1), and **never** under `~/knowledge/wiki/` so it cannot pollute `knowledge_search`.

### Components (well-bounded units)

| Unit | Responsibility | Depends on |
|---|---|---|
| `kb-schema.json` `raw` group | the one declaration of the inbox structure | — |
| `mcp/src/tools/raw-inbox.ts` (pure) | item id/format helpers, frontmatter (de)serialise, `captureItem`, `listItems`, `setStatus`, `unprocessedCount` | `doc-sources.ts` `hashContent`/`assertSafeSlug` (reuse) |
| `mcp/src/tools/raw-capture-cli.ts` (thin bundle) | deterministic file work the skill calls — no bash/TS logic drift | `raw-inbox.ts` |
| `skills/capture/SKILL.md` | the user-facing producer (`/second-brain:capture`) | `raw-capture-cli` bundle, active-slug resolution |
| `scripts/kb-schema.sh` + `constants/kb-schema.ts` | expose the `raw` group to both sides | `kb-schema.json` |
| `scripts/session-load.sh` | low-priority backlog banner | `raw-inbox` count helper |
| `knowledge_validate` | gentle warning on malformed raw frontmatter | `raw-inbox.ts` parse |

---

## Data model

### Item file: `raw/<id>.md`

```yaml
---
id: 20260603T141500Z-auth-spec     # <UTC-compact-stamp>-<short-kebab-slug>; sortable + unique
source: /home/me/Downloads/auth-spec.pdf   # absolute path | https://… | "paste"
captured_at: 2026-06-03T14:15:00Z          # ISO-8601 UTC
captured_by: user                          # user | setup-scan | dream  (closed vocab; forward-compat)
content_type: application/pdf              # MIME-ish: text/markdown, text/html, text/uri-list, application/pdf, …
status: unprocessed                        # unprocessed | processed | discarded
target_node:                               # OPTIONAL active-wiki slug this item backs (provenance only)
blob: 20260603T141500Z-auth-spec.pdf       # OPTIONAL sibling filename when the original is binary
gist: One-line human summary of the item.
---

<captured text for text/paste items; for a binary item this body holds the gist /
a short description only — the bytes live in the sibling `blob` file.>
```

**Rules**

- **id** = `date -u +%Y%m%dT%H%M%SZ` + `-` + a short kebab slug derived from the source filename / first words of paste / URL host. Collision-safe: if the file already exists, append a `-2`, `-3`, … suffix.
- **text / paste / text file** → content_type `text/markdown` (or the file's type); the content goes in the `.md` body; no `blob`.
- **binary file** (anything not detected as text) → copy the original to `raw/<id>.<ext>` and set `blob:`; the `.md` is a manifest whose body is the gist only. No parsing in SP-2.
- **bare URL** → content_type `text/uri-list`; body is the URL; `source` is the URL; no fetch.
- **status** is a closed vocabulary `unprocessed | processed | discarded`. SP-2 writes `unprocessed` on capture and `discarded` via `--discard`; `processed` is reserved for SP-4 (the manual contract is documented so SP-4 has a fixed target).
- **target_node** is a plain slug (never a `[[link]]`), optional, recording which existing wiki page the item is evidence for. SP-2 only stores it; the raw→node **edge** is projected later by SP-4 through a sanctioned writer (SP-2 never writes graph edges).

### Work-list = derived, never stored

The backlog/work-list is **computed** by scanning `raw/*.md` for `status: unprocessed` (the same derive-don't-store discipline as `kb-ai-block-candidates.sh`). There is **no** separate index file — status lives only in each item's frontmatter, so the two can never disagree. This honours the "single source of truth" value.

### kb-schema.json addition

```json
"raw": {
  "dir": "raw",
  "tier": "project",
  "statuses": ["unprocessed", "processed", "discarded"],
  "searchable": false
}
```

Read by `mcp/src/constants/kb-schema.ts` (esbuild-inlined) and `scripts/kb-schema.sh` (jq → `SB_RAW_*` vars), per the established dual-reader pattern. `test-kb-schema.sh` asserts both sides see it.

---

## Producer — `/second-brain:capture`

A new **user-invocable** skill (`user-invocable: true`, `disable-model-invocation: true`, like `import-host`). It maps an argument to a `raw-capture-cli` action and reports the result.

```
/second-brain:capture <path>            # copy a file into the active project's inbox
/second-brain:capture <url>             # record a URL pointer (no fetch)
/second-brain:capture --paste           # capture piped/pasted text from stdin
/second-brain:capture --node <slug> …   # also set target_node (pre-attach to a wiki page)
/second-brain:capture --list            # list this project's inbox items (id, status, gist)
/second-brain:capture --discard <id>    # mark an item discarded
```

Behaviour:

1. Resolve the active project slug via the existing pin (`~/.second-brain/.active-session-slug`, `assertSafeSlug`). If no active project, report and stop (capture is project-scoped).
2. `captureItem` (in `raw-inbox.ts`): classify the source (file/url/paste), stamp provenance, copy the blob via node `fs` (portable — not `cp`), write the `.md`, create `raw/` if absent.
3. **Idempotent**: if an item with the same `source` content hash already exists and is `unprocessed`, do not duplicate — report the existing id (`hashContent` reuse).
4. Print the new (or existing) id and the current `unprocessedCount`.

`raw-capture-cli` is a thin bundle so the skill carries no logic; all classification/file work is in the tested pure module.

---

## Surfacing + lifecycle

- **Backlog banner.** `session-load.sh` adds one low-priority line — `raw: N unprocessed item(s) — /second-brain:capture --list` — for the **active project** only, gated by `SB_RAW_INBOX=off`. The count comes from a cheap scan of the project's `raw/`. Mirrors the existing `conflicts.jsonl` banner pattern (advisory, never blocks).
- **Directory creation.** `raw/` is created **on demand** by `captureItem` (`mkdir -p`); `ensure-dirs.sh` is intentionally **not** modified, so projects that never capture get no empty `raw/` litter.
- **Out of search.** Raw items are never indexed by `knowledge_search` (they are unprocessed and not under `wiki/`). They surface only as the count and via `--list`.
- **Drain (SP-4, deferred).** The maintainer will read the derived unprocessed work-list, turn each item into wiki node(s) (or attach to `target_node`), set `status: processed`, and project the raw→node edge. SP-2 fixes the contract (location, fields, status vocab) so SP-4 has a stable target.

## Error handling

- Missing/!active project → capture refuses with a clear message (no global inbox).
- Unsafe slug → `assertSafeSlug` throws (reused).
- Unreadable source file → report and skip; never partially write an item.
- Malformed raw frontmatter encountered later → `knowledge_validate` emits a **gentle warning** (raw is messy by nature; never an error, never autofixed-away).
- All file ops fail-safe: write to a temp name then atomic rename (the `doc-sources` write pattern), so an interrupted capture leaves no half-item.

## Cross-platform

mawk-safe bash (no shell-var interpolation into awk; `-v` + coercion); portable (`stat -c||-f`, `timeout||gtimeout`, no `mapfile`, no `grep -P`); file copy through node `fs` so Windows backslash paths are handled by the existing `toBashPath` where a bash→node path crossing occurs.

## Testing (TDD)

| Test | Covers |
|---|---|
| `raw-inbox.test.ts` (vitest) | id format + collision suffix; capture of file (blob+sidecar), paste (body), URL (uri-list pointer); `hashContent` dedup idempotency; `assertSafeSlug` guard; `target_node` set; `setStatus` transitions; `unprocessedCount` |
| `test-raw-capture.sh` (bash) | skill→CLI end-to-end: capture a temp file → item appears with correct frontmatter → re-capture is idempotent → `--list` shows it → `--discard` flips status → backlog count |
| `test-kb-schema.sh` (extend) | the `raw` group is visible to **both** `kb-schema.sh` (`SB_RAW_*`) and `constants/kb-schema.ts` |
| `test-raw-inbox-banner.sh` (bash) | `session-load` prints the unprocessed count; `SB_RAW_INBOX=off` suppresses it; zero items → no line |
| validate case | malformed raw frontmatter → gentle warning, not error |

## Versioning

Plugin patch bump + migration row (additive, no state migration — `raw/` appears lazily on first capture). MCP server minor bump justified by `knowledge_validate` gaining raw-frontmatter awareness + the new `raw-capture-cli` bundle (no new MCP server *tool* is registered — capture rides a standalone CLI bundle, like `knowledge-search-cli`). Back-compat: with no captures and `SB_RAW_INBOX` unset, behaviour is unchanged.
