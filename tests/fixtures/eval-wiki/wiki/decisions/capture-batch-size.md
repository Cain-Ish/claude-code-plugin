---
title: Capture batch size five
type: decisions
description: "decision: drain five transcripts per batch"
---
<!-- ai:begin (authored — flat YAML, see ai-block schema) -->
context: unbounded batches starved the session that triggered them
choice: drain five transcripts per batch
alternatives: unbounded batch; one per tick
rationale: five bounds worst-case latency while keeping the queue moving
status: active
<!-- ai:end -->

The capture batch size is five: each tick the pipeline will drain five transcripts per batch, bounding worst-case latency.
