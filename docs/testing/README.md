# Testing

These tests are the QA engineer's domain. Unit tests are out of scope —
this repo is a single PowerShell script; unit-level testing is handled
inside the script by fail-fast probes and post-checks.

## Environment

### clean-win11-vm

The VirtualBox VM `bootstrap-test-win11`, restored to its `fresh` snapshot
(Windows 11 Home, user `tester` logged in, Guest Additions running,
nothing bootstrapped). Everything about building, driving and trusting it
is in [`tests/vm/README.md`](../../tests/vm/README.md), including the
gotchas that make naive runs lie, e.g. Task Scheduler windows where
browsers never open, and stale screenshots.

- PowerShell 5.1 (ships with Windows 11). No winget dependency for Git or
  gh.
- Network access to `github.com`, `raw.githubusercontent.com`, and
  `claude.ai`.
- The window under test must be a **real user window**: started by the
  shell, non-elevated, no `-ExecutionPolicy` override. `vmctl.py launch`
  does this.

### Sign-in coverage

Steps 1–7 need no account; `vmctl.py e2e` covers them unattended
(`BOOTSTRAP_STOP_BEFORE_SIGNIN=1`). Steps 8–15 need the real Claude and
GitHub sign-ins. Run them on the real target machine, or in the VM with
**dedicated test accounts**. Never put personal work credentials into a
VM an agent can reach. Restore `fresh` after any signed-in run.

## How to run the suite

- `python tests/vm/vmctl.py e2e` runs the automated pre-sign-in card
  (`test-bootstrap-presignin-vm-e2e`).
- The other cards are run manually or by QA subagents dispatched by
  `/extremis:run-test-cases`. Each card's frontmatter describes the
  starting state and the assertion to check.

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
