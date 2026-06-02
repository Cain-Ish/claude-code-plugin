---
title: OAuth bare flag incompat
description: claude --bare rejects OAuth tokens
---
<!-- ai:begin (authored — flat YAML, see ai-block schema) -->
claim: claude --bare rejects OAuth subscription tokens
trigger: running claude --bare with only a subscription login
action: export ANTHROPIC_API_KEY so --bare has a key
scope: the --bare execution mode
<!-- ai:end -->

The claude --bare flag rejects OAuth subscription tokens and requires an API key.
