---
title: Retry backoff doubling choice
type: decisions
description: "decision: doubling backoff for failed drains"
---
<!-- ai:begin (authored — flat YAML, see ai-block schema) -->
context: failed drains retried instantly and hammered the queue
choice: doubling backoff starting at one minute
alternatives: fixed interval; no retry
rationale: doubling spaces retries without abandoning the item
status: active
<!-- ai:end -->

We choose a doubling backoff for failed drains: retries start at one minute and double each attempt.
