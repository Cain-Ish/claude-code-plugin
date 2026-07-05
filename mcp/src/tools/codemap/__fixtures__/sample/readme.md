# scanSources fixture

Committed part of the Task A1 fixture tree (trackable files only). The
must-be-excluded dirs (node_modules/, dist/, build/, coverage/, vendor/,
.next/, out/, .git/) are materialized by scan-sources.test.ts in a temp
copy at runtime: the repo-root .gitignore has a bare `node_modules/` rule,
so committing them here would silently drop them from fresh clones.

This readme itself doubles as a fixture: `.md` is not a v1 lang, so the
scanner must drop it.
