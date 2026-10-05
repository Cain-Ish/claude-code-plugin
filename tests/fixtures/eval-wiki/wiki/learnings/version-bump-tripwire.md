---
title: "Version bump tripwire"
type: learnings
description: "a manifest edit without a matching version bump fails the release tripwire"
project: brainplug
tags: [release, tripwire]
---

The release tripwire compares the manifest against the marketplace entry. Editing one without
bumping the version in both fails the gate, which keeps a shipped surface change from going
out under an old version number.
