---
title: "Pool sync over-cancels jobs"
type: learnings
description: "sync cancels every queued job when any key moves, relevant or not, so everything restarts"
---

The worker pool cancels all in-flight jobs on any key update instead of only the keys that
feed the ranking engine, which throws away finished work on every unrelated toggle.
