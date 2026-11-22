# Project guide for Claude

Only what Claude cannot learn from the code belongs here; keep it short.

## Check your work
- Test:
- Lint:
- Build:

## Team memory
This project's decisions live in `.project-map/`, one topic file per area. Before you change an area, read its
topic file. When someone states a new decision, record it there, in the format `.project-map/README.md` gives.
To check a change or a plan against these decisions, hand it to the `decision-checker` agent, even after you have
read the map yourself: it also checks `.claude/rules/`, and it keeps notes on what earlier checks missed. For
where-is and how-do-we questions about the code, use the `codebase-guide` agent.
