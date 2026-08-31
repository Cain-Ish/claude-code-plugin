---
title: "Archived Project Decisions — projx"
type: decisions
description: "Auto-archived decisions rotated out of PROJECT.md hot tier"
created: 2026-05-01T00:00:00Z
updated: 2026-05-03T00:00:00Z
project: projx
---

# Archived Project Decisions — projx

- [2026-05-01] [decision] chose flock over mkdir for the lock because flock releases on process death (rejected: mkdir — stale dir survives a crash)
- [2026-05-03] [decision] chose jsonl over sqlite for the ledger because zero native deps (rejected: sqlite — node-gyp build breaks the portability rule)
