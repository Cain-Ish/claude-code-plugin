---
title: "Enemy team data flow"
type: learnings
description: "how opponent composition reaches the scoring engine per activity mode; only arena feeds an enemy list"
project: gamehelper
tags: [enemy, opponent]
---

Only the arena activity hands an opponent list to the scoring engine. Supreme arena has the
plumbing but nothing fills it, and the boss activities never read an opponent at all, so a
counter bonus can only ever apply in the arena.
