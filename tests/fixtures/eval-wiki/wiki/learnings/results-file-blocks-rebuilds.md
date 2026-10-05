---
title: "Results file blocks rebuilds"
type: learnings
description: "one bad results file added to a new build blocks every other build step"
---

The bundler reads every results file first and aborts on the first parse error, so a single
malformed file stops the hero, tier and meta outputs from being regenerated at all.
