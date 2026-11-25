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

### how work is built and verified
> remember to use plugins and agents already exist plus do not overengineer - in verification check if code can be rewrie to be shorter and smarter than do it. think before implement code

- id: reuse-existing-no-overengineering
- source: the user (said in three sessions), 2026-11-23
- when: ["building or changing the plugin", "verifying a step"]
- origin: dream 2026-11-25
- verified: 2026-11-25 accepted in review

### systems the checks run on
> Skip Linux for now and focus on windows and mac only

- id: skip-linux-for-now
- source: the user, 2026-11-24
- when: ["testing", "choosing the systems a check runs on"]
- origin: dream 2026-11-25
- verified: 2026-11-25 accepted in review
