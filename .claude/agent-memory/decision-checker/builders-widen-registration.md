---
name: builders-widen-registration
description: Recurring break - a step's builder implements a wider or different mechanism than the step registered (seen 8j, 8k)
metadata:
  type: project
---

A builder replaces a registered mechanism with a "better" one that the registration never named. In 8j, the builder "went wider than registered" (06 records this). In 8k, the index.ignore fallback probes each line on its own where the registration re-ran the call once without any of the file's lines, and the excludes gained `glob` magic and a `/**` pair.

**Why:** the user's rule is that every check is pre-registered. A widened mechanism runs on paths that no registered check covers, and it can break the registered guarantee in edge cases.

**How to apply:** for every registered mechanism, compare the code's actual path, including its failure path, against the registration's wording. Report each difference as unregistered, or as a break when it voids a registered guarantee. Related: [[decision-checker-scope]]
