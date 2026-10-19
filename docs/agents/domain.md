# Domain docs

How engineering skills should use this repo's domain documentation on branch `v2`.

## Before exploring, read these

- `docs/v2/GLOSSARY.md`, if it exists. If it does not, proceed silently; `/domain-modeling` creates it when a term
  actually gets resolved.
- `docs/v2/DECISIONS.md`: the decisions that touch the area you are working in. A LOCKED decision is settled.
- `docs/v2/00-charter.md`: what v2 is and is not.

## Recording a decision

This overrides the ADR format in `/domain-modeling`. Never create `docs/adr/`. A decision is a record in
`docs/v2/DECISIONS.md`, in the format and under the rules of `docs/v2/01-process.md`.

## Use the glossary's vocabulary

When your output names a domain concept (an issue title, a proposal, a test name), use the term as the glossary
defines it. A concept with no glossary entry is a signal: either the language is new to the project (reconsider)
or there is a real gap (note it for `/domain-modeling`).

## Flag decision conflicts

If your output contradicts a recorded decision, say so explicitly instead of silently overriding it:

> _Contradicts V2-Dnn (summary). Reopen trigger that fired: …_

Without a fired trigger, the decision stands.
