---
name: bootstrap-wrong-claude-account
kind: regression
status: draft
timeout: 900
env: clean-win11-vm
covers:
  - ac-claude-wrong-account
---

# Wrong Claude account recovery — Step 4 logout-and-re-auth

Run `bootstrap.ps1` on a Windows 11 host where `claude` is already
installed and authed as a DIFFERENT email, and verify that Step 4
(`Ensure-ClaudeAuth`) detects the mismatch, logs the wrong account out,
prompts the operator to log in as the expected email, re-probes, and
finishes with `claude auth status` reporting
`jonathan.wheeler@lifemaideasier.com`.

## Prerequisites

- A Windows 11 VM or host restored to a clean snapshot.
- PowerShell 5.1 available (ships with Windows 11).
- `winget` on PATH (ships with Windows 11; verify once before starting).
- Network access to `github.com`, `raw.githubusercontent.com`, and
  `claude.ai`.
- The QA operator has credentials for **two** Claude-capable identities:
  - **Decoy account** — any Claude account whose email is NOT
    `jonathan.wheeler@lifemaideasier.com` (e.g., a personal test
    account). Used to seed the wrong-state precondition.
  - **Expected account** — `jonathan.wheeler@lifemaideasier.com` via
    OAuth in a browser. Used to satisfy the AC.
- The operator also has credentials for the `tokuro-sedai` GitHub
  user account (associated email `jonathan.wheeler@witechnologies.org`)
  — required so the run reaches Step 4 by completing earlier steps;
  this card does not assert against `gh`.
- The operator is logged into Windows as a **non-administrator** user.

## Setup

1. Restore the VM to its clean snapshot.
2. Open a non-elevated PowerShell window (NOT "Run as Administrator").
3. Pre-install Claude Code as a precondition (the script's Step 3 would
   normally do this; we do it here to seed Step 4's wrong-state):
   ```powershell
   irm https://claude.ai/install.ps1 | iex
   ```
   Then add `%USERPROFILE%\.local\bin` to the current session's PATH so
   `claude` resolves:
   ```powershell
   $env:PATH = "$env:USERPROFILE\.local\bin;$env:PATH"
   ```
4. Pre-auth `claude` as the **decoy** account (NOT the expected email):
   ```powershell
   claude auth login
   ```
   Complete the browser OAuth flow as the decoy identity.
5. Confirm the wrong-state precondition before running the script:
   ```powershell
   $before = claude auth status
   $before
   ```
   The output must show an authed email, and that email must NOT be
   `jonathan.wheeler@lifemaideasier.com`. If it does match, the
   precondition is wrong — restart from step 1 with a different decoy.
6. Capture the decoy email for the Pass Criteria comparison:
   ```powershell
   $decoyEmail = ($before | Select-String -Pattern '[\w\.-]+@[\w\.-]+').Matches[0].Value
   $decoyEmail
   ```

## Procedure

1. In the same PowerShell window, paste:
   ```powershell
   irm https://raw.githubusercontent.com/tokuro-sedai/bootstrap/main/bootstrap.ps1 | iex
   ```
2. Steps 1–3 should print "already satisfied" (git is installed by the
   script if missing; claude is already on PATH from Setup).
3. When Step 4 runs, observe the script:
   - Probe reports the decoy email as the current authed account.
   - Script announces it is logging the wrong account out.
   - `claude auth login` opens a browser.
4. Complete the OAuth flow as `jonathan.wheeler@lifemaideasier.com`.
5. When `gh auth login` prompts (Step 5), complete OAuth as
   `jonathan.wheeler@witechnologies.org`. (Required only so the run
   reaches its success banner; not asserted by this card.)
6. Wait for the script to report `ecosystem bootstrap complete.`.

## Pass Criteria

ALL must pass for this card.

- **ac-claude-wrong-account: pre-state observed** — The Setup step 5
  output established that `claude auth status` reported an email that
  is not `jonathan.wheeler@lifemaideasier.com`. Recorded in `$decoyEmail`.
- **ac-claude-wrong-account: logout-then-login executed** — During the
  script run, Step 4's status line indicated the wrong-account branch
  was taken (the line is NOT `already satisfied`; it reflects a
  re-auth, e.g. `re-authed` / `logged out and re-authed` / similar).
  The browser OAuth prompt was presented exactly once during Step 4.
- **ac-claude-wrong-account: post-state matches expected email** — In
  the SAME PowerShell window after the success banner:
  ```powershell
  $after = claude auth status
  $after
  $afterEmail = ($after | Select-String -Pattern '[\w\.-]+@[\w\.-]+').Matches[0].Value
  $afterEmail -eq 'jonathan.wheeler@lifemaideasier.com'
  ```
  The final expression evaluates to `True`.
- **ac-claude-wrong-account: email actually changed** — `$afterEmail`
  is NOT equal to `$decoyEmail`:
  ```powershell
  $afterEmail -ne $decoyEmail
  ```
  evaluates to `True`. (Guards against a probe that falsely reports
  "ok" without performing the swap.)
- **Run terminated successfully** — The script printed the literal
  line `ecosystem bootstrap complete.` and PowerShell's `$LASTEXITCODE`
  / last `$?` indicates success.

## Fail-Fast

- If the precondition in Setup step 5 shows
  `jonathan.wheeler@lifemaideasier.com` as the current authed email,
  the wrong-state was not seeded — abort, do NOT run the script,
  reset the VM, and retry with a different decoy. This is a setup
  defect, not a card FAIL.
- If Step 4 prints `already satisfied` while the decoy email was
  active, mark FAIL immediately (the probe failed to detect the
  mismatch — the AC is violated).
- If the script does not print `ecosystem bootstrap complete.` within
  the timeout, mark the card FAIL.
- If at any point a UAC prompt appears or PowerShell displays an
  ExecutionPolicy error, mark FAIL immediately (these are precondition
  violations that mask the real assertion).

## Teardown

- Restore the VM to its clean snapshot. Do not attempt to "clean up"
  by running `claude auth logout` manually — the VM has accumulated
  global state (PATH, plugin cache, gh credential helper, arcturus
  checkout) from the successful run that will contaminate any
  subsequent clean-state card.
- Do not reuse the decoy account for the next test card without
  resetting credentials; the script logged it out, but the OAuth
  session in the browser may persist.

## Notes

- The `env: clean-win11-vm` reference is to the **Environment** section
  of `docs/testing/README.md`.
- This card targets exactly one AC (`ac-claude-wrong-account`) and
  uses `kind: regression` because it guards Step 4's verify-and-re-auth
  policy described in the design spec
  (`docs/superpowers/specs/2026-04-24-ecosystem-bootstrap-design.md`,
  Step 4 — Ensure-ClaudeAuth). A future regression in which the probe
  tolerates "any authed email" would be caught by this card.
- Email parsing uses a deliberately broad regex
  (`[\w\.-]+@[\w\.-]+`); if the `claude auth status` output format
  changes to embed multiple emails, revisit this card before relying
  on `Matches[0]`.
- The decoy account does NOT need access to the `tokuro-sedai` org
  or any private resources — it only has to be a different valid
  Claude login than the expected one.
