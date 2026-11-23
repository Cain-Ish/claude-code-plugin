---
name: decisions
description: Working rules for this repo that are not v2's ledger decisions (those live in docs/v2/DECISIONS.md). Read it before releasing or changing the repo's setup.
---
# Decisions

### releases
> Merging `v2` into `main` deletes the branch `v2` on GitHub, because the repo deletes a pull request's head branch on merge. Push `v2` back from the local copy right after the merge.

- id: v2-branch-deleted-on-merge
- source: found while merging PR #117, 2026-11-23
- when: ["merging v2 into main", "releasing"]
- verified: 2026-11-23 seen: the branch was deleted and PR #118 was retargeted to main
