---
name: bootstrap-wrong-git-identity
kind: regression
status: draft
timeout: 900
env: clean-win11-vm
covers:
  - ac-git-identity-overwrite
---

# Wrong git-identity recovery — bootstrap.ps1 overwrites mismatched global config

Run `bootstrap.ps1` on a Windows 11 host where `git` is already installed
and the global `user.name` / `user.email` are pre-set to unrelated values.
Verify Step 2 (Ensure-GitConfig) detects the mismatch and overwrites both
keys to the expected `Tokuro` / `jonathan.wheeler@witechnologies.org`
identity, and that the rest of the script proceeds normally.

## Prerequisites

- A Windows 11 VM or host restored to a clean snapshot, then modified
  per Setup below: `git` installed, but no `claude`, `gh`, `extremis`,
  `superpowers`, or arcturus checkout. (The Step 1 probe will report
  "already satisfied" for git, which is expected and not under test
  here.)
- PowerShell 5.1 available (ships with Windows 11).
- `winget` on PATH.
- Network access to `github.com`, `raw.githubusercontent.com`, and
  `claude.ai`.
- QA operator has credentials to log into:
  - `jonathan.wheeler@lifemaideasier.com` (Claude) via OAuth in a
    browser.
  - `jonathan.wheeler@witechnologies.org` with `tokuro-sedai` org
    access (GitHub) via OAuth in a browser.
- The operator is logged into Windows as a non-administrator user.

## Setup

1. Restore the VM to its clean snapshot.
2. Open a non-elevated PowerShell window.
3. Install git only (so we can pre-set its identity before the
   bootstrap script runs):
   ```powershell
   winget install --id Git.Git -e --source winget --silent
   ```
   Then refresh PATH for the current session, or open a new
   non-elevated PowerShell window.
4. Pre-set the global identity to UNRELATED values:
   ```powershell
   git config --global user.name 'Some Other Person'
   git config --global user.email 'someone@elsewhere.com'
   ```
5. Confirm the wrong-identity starting state (record this output as
   the "before" baseline for Pass Criteria):
   ```powershell
   git config --global user.name    # → Some Other Person
   git config --global user.email   # → someone@elsewhere.com
   ```
6. Confirm baseline absence of the rest of the ecosystem:
   ```powershell
   Get-Command claude, gh -ErrorAction SilentlyContinue
   ```
   Expect: no output.

## Procedure

1. In the same non-elevated PowerShell window, paste:
   ```powershell
   irm https://raw.githubusercontent.com/tokuro-sedai/bootstrap/main/bootstrap.ps1 | iex
   ```
2. Observe Step 2's status line. Expected shape:
   `[2/8] git config           ... set (Tokuro <jonathan.wheeler@witechnologies.org>)`
   (i.e., not "already satisfied" — the probe must detect the
   mismatch and the fix must run).
3. When `claude auth login` opens a browser, complete OAuth as
   `jonathan.wheeler@lifemaideasier.com`.
4. When `gh auth login` prompts and opens a browser, complete OAuth
   as `jonathan.wheeler@witechnologies.org`.
5. Wait for the script to report `ecosystem bootstrap complete.`.

## Pass Criteria

All bullets must pass.

- **Before-state captured** — Setup step 5 recorded `Some Other Person`
  / `someone@elsewhere.com` as the pre-run global identity. (This is
  the precondition; if it doesn't hold, the test is invalid, not
  failed.)
- **ac-git-identity-overwrite (after-state)** — After the script
  reports `ecosystem bootstrap complete.`, in any PowerShell window:
  ```powershell
  git config --global user.name    # → Tokuro
  git config --global user.email   # → jonathan.wheeler@witechnologies.org
  ```
  Both keys MUST report the new expected values. Neither may retain
  any portion of the pre-set `Some Other Person` /
  `someone@elsewhere.com` strings.
- **Step 2 ran the fix path** — The Step 2 status line in the script
  output reads `set (...)` or equivalent "changed" detail, not
  `already satisfied`. (Confirms the probe detected mismatch rather
  than silently accepting wrong values.)
- **Script completed end-to-end** — The output ends with the literal
  line `ecosystem bootstrap complete.` and the process exit code is
  zero. (A regression in Step 2 must not gate later steps; the wrong
  identity is recoverable, not fatal.)

## Fail-Fast

- If after Setup the global identity is NOT `Some Other Person` /
  `someone@elsewhere.com`, abort the run — the precondition is not
  satisfied, so any pass/fail signal would be meaningless. Reset and
  redo Setup.
- If the script does not print `ecosystem bootstrap complete.` within
  the timeout, mark the card FAIL.
- If Step 2's status line reads `already satisfied` despite the
  pre-set wrong values, mark FAIL immediately — this is the exact
  defect this card guards against.
- If, after the script completes, either `git config --global
  user.name` or `git config --global user.email` still reflects the
  pre-set wrong value (in whole or in part), mark FAIL.

## Teardown

- Restore the VM to the clean snapshot before running any other
  bootstrap test card. The script has installed global state (PATH,
  user-level configs, plugin cache, arcturus clone) and rewritten
  global git identity; both will contaminate subsequent clean-state
  tests.

## Notes

- This card is `kind: regression` because it guards against a specific
  failure mode (Step 2's probe accepting a non-matching pre-set
  identity instead of overwriting). It tests one AC narrowly and
  deliberately leaves the other seven steps' post-conditions to the
  fresh-VM smoke card.
- The `env: clean-win11-vm` reference is to the **Environment**
  section of `docs/testing/README.md`, with the Setup deviation that
  `git` is pre-installed and pre-configured with wrong identity.
- Choice of `Some Other Person` / `someone@elsewhere.com` for the
  pre-set wrong values is arbitrary; any pair distinct from
  `Tokuro` / `jonathan.wheeler@witechnologies.org` is equivalent for
  this card's purposes.
