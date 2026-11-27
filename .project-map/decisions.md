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

### the implementation plan
> If you find issue, gaps, improvement do not leave it and add it to the implementation plan - remember that because we skip it and lose track of them

- id: findings-go-into-the-plan
- source: the user, 2026-11-25
- when: ["reviewing or auditing", "live testing", "finding an issue, gap or improvement", "ending a step"]
- verified: 2026-11-25 stated by the user

### probe runs and their limits
> we have subscription for claude so cost is not a issue - more usage limit and restarts

- id: usage-limits-not-usd
- source: the user, 2026-10-22
- when: ["planning or running probes", "deciding whether to stop and ask"]
- verified: 2026-11-25 copied from the agent's notes, where it was saved on 2026-10-22

### checking that planned work is finished
> make a full status check of all features, improvements and changes. compare them with the planned features to add. confirm if all is added … add changes if needed and ponytail audit at the end

- id: full-status-check-then-audit
- source: the user (said in two sessions), 2026-11-25
- when: ["checking that planned work is finished", "before a release"]
- origin: dream 2026-11-27
- verified: 2026-11-27 accepted in review

### commits while another session shares the working tree
> commit explicit paths only; … re-read the tail of 06 before you append to it; … run `git pull --rebase` before pushing

- id: shared-tree-commits
- source: the user, 2026-11-25
- when: ["committing or pushing while another session works in this repo"]
- origin: dream 2026-11-27
- verified: 2026-11-27 accepted in review

### long runs
> keep track of repeats and time - react to not lose time and tokens

- id: track-repeats-and-time
- source: the user, 2026-11-26
- when: ["long or unattended runs", "retrying a step that keeps failing"]
- origin: dream 2026-11-27
- verified: 2026-11-27 accepted in review

### cleaning up after a run
> remember to clean up when you finish it cause last time similar session left 8gb leftovers

- id: clean-up-leftovers
- source: the user, 2026-11-26
- when: ["ending a run that made copies, worktrees or temp folders"]
- origin: dream 2026-11-27
- verified: 2026-11-27 accepted in review

### guidelines for making agents and skills
> agents build should have general guidelines so claude will know how to create best agents based on the research we done and will done to improve that logic. also self-improvement loop need to know it

- id: research-feeds-the-guidelines
- source: the user, 2026-11-27
- when: ["researching how agents or skills are made", "changing tailor's guidelines or the dream's drafts"]
- verified: 2026-11-27 stated by the user

### what the installed plugin can rely on
> we will use plugin in different repos so they wont have access to anything that installed plugin do not contain

- id: plugin-is-self-contained
- source: the user, 2026-11-27
- when: ["building or changing the plugin", "writing text a skill or agent of the plugin reads"]
- verified: 2026-11-27 stated by the user
