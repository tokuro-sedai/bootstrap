# Testing

These tests are the QA engineer's domain. Unit tests are out of scope —
this repo is a single PowerShell script; unit-level testing is handled
inside the script by fail-fast probes and post-checks.

## Environment

A clean Windows 11 host (physical or VM) with:

- PowerShell 5.1 (ships with Windows 11).
- `winget` available on PATH.
- Network access to `github.com`, `raw.githubusercontent.com`, and
  `claude.ai`.
- Browser available for the interactive OAuth steps
  (`claude auth login`, `gh auth login`).

VM snapshots are the recommended way to reset between runs.

## How to run the suite

Test cards are run manually: each card's frontmatter describes the
starting state and the assertion to check. QA subagents dispatched by
`/extremis:run-test-cases` execute each card against the declared env.

## Test kinds

Allowed kinds for test cards in `tests/qa/`:

- `smoke` — quick sanity check that the system comes up
- `integration` — component boundaries
- `e2e` — full user flow through the whole system
- `regression` — guards against past bugs
- `acceptance` — ties to a specific feature acceptance criterion

## Test-card frontmatter schema

```yaml
---
name: <test-slug>
kind: smoke | integration | e2e | regression | acceptance
status: draft | active | deprecated
timeout: <seconds>   # integer seconds — not milliseconds
env: <reference to a section above, or inline>
covers: [<feature-or-AC-slug>, ...]
---
```

## Conventions

- Timeouts are in seconds.
- `unit` is not a valid kind.
- Most cards for this repo will be `acceptance` (tied to an AC in the
  design spec) or `smoke` (fresh-VM end-to-end).
