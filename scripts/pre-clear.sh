#!/bin/bash
# Create a pending reflection when the user clears the session (/clear).
# Runs on SessionStart with "clear" matcher, BEFORE the main hook chain.
# The actual reflection (LLM analysis) happens in the same SessionStart
# via session-load.sh, which picks up .pending-reflections.jsonl.

source "$(dirname "$0")/lib.sh"

sb_collect_session_data 3 || exit 0

sb_write_reflection "clear"
sb_write_session_meta

exit 0
