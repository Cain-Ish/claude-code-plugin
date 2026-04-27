#!/bin/bash
# Runs after context compaction.
# Kept minimal — session-load.sh handles brain file loading and reflection
# processing on the SessionStart "compact" event. Having both scripts emit
# read instructions would cause double-loading and waste tokens.

echo "Context compacted. Session reload follows."
