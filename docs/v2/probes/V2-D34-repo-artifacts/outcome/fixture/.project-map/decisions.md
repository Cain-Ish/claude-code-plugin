---
name: decisions
description: Project-wide decisions that fit no other topic file. Read it before any change.
---
# Decisions

### Database migrations: numbering
> Core team migrations take the next free number in the core range in db/reserved.txt, never just the highest file plus one: the numbers above the core range belong to other teams.

- id: migrations-core-range
- source: lead developer, 2026-11-02
- when: ["adding a database migration"]
- verified: 2026-11-02 stated by the lead developer

### Database migrations: rollback
> Every migration has a rollback file next to it, NNNN_name.down.sql, which undoes it exactly.

- id: migrations-rollback
- source: lead developer, 2026-11-02
- when: ["adding a database migration"]
- verified: 2026-11-02 stated by the lead developer

### Database migrations: check
> After adding a migration, run node scripts/check-migrations.js; it must print OK.

- id: migrations-check
- source: lead developer, 2026-11-05
- when: ["adding a database migration"]
- verified: 2026-11-05 stated by the lead developer
