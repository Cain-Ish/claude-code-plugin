#!/bin/bash
# Quality gate instruction injected after every Write/Edit via stdout.
# Kept as a script (not inline echo) so the instruction text can evolve.
echo "QUALITY GATE - Silently self-review what you just wrote against the quality rules and persona loaded at session start. Check: gaps, correctness, security, completeness, consistency, human-style code. Fix issues immediately. Do not narrate."
