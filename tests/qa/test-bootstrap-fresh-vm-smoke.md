---
name: bootstrap-fresh-vm-smoke
kind: smoke
status: draft
timeout: 900
env: clean-win11-vm
covers:
  - ac-git-on-path
  - ac-git-identity
  - ac-claude-on-path
  - ac-claude-authed
  - ac-gh-authed-and-credhelper
  - ac-extremis-installed
  - ac-superpowers-installed
  - ac-arcturus-cloned
  - ac-arcturus-new-window
  - ac-status-line-per-step
  - ac-no-admin-required
  - ac-fetchable-via-irm
---

# Fresh-VM smoke — bootstrap.ps1 end-to-end

Run `bootstrap.ps1` on a pristine Windows 11 host and verify every
post-condition of a successful ecosystem bootstrap.

## Prerequisites

- A Windows 11 VM or host restored to a clean snapshot with no prior
  install of `git`, `claude`, `gh`, `extremis`, or `superpowers`. No
  arcturus checkout anywhere on disk.
- PowerShell 5.1 available (ships with Windows 11).
- Network access to `github.com`, `raw.githubusercontent.com`, and
  `claude.ai`.
- A person who can complete the Claude (`jonathan.wheeler@witechnologies.org`)
  and GitHub (`tokuro-sedai`) sign-ins in a browser. Run this card on the real
  target machine, or with dedicated test accounts. Never enter personal work
  credentials in a VM an agent can reach.
- The operator is logged into Windows as a **non-administrator** user
  (covers `ac-no-admin-required`).

## Setup

1. Restore the VM to its clean snapshot.
2. Open a non-elevated PowerShell window from Start (NOT "Run as Administrator",
   and not one launched by Task Scheduler: browsers can't open from those).
3. Confirm baseline with:
   ```powershell
   Get-Command git, claude, gh -ErrorAction SilentlyContinue
   ```
   Expect: no output (none of the three should resolve).

## Procedure

1. In the same PowerShell window, paste:
   ```powershell
   irm https://raw.githubusercontent.com/tokuro-sedai/bootstrap/main/bootstrap.ps1 | iex
   ```
2. At step 8, complete the Claude sign-in as `jonathan.wheeler@witechnologies.org`
   (a browser opens; otherwise Ctrl+click the printed link and paste the code back).
3. At step 9, enter the gh device code in the browser and approve as `tokuro-sedai`.
   There must be no "Authenticate Git (Y/n)" question and no "Select a credential
   helper" dialog.
4. Wait for the script to report `ecosystem bootstrap complete.`.

## Pass Criteria

Each bullet is independently verifiable. ALL must pass.

- **ac-fetchable-via-irm** — The `irm ... | iex` invocation ran without
  an ExecutionPolicy prompt or failure. The script executed in the
  current session.
- **ac-status-line-per-step** — The output contains exactly fifteen
  status lines, one per step, each matching
  `^\[\d+/15\] \S.* \.{3}` and the run ends with the literal line
  `ecosystem bootstrap complete.`.
- **ac-no-admin-required** — The PowerShell window was non-elevated
  throughout; no UAC prompt appeared. (Observe: the window title
  shows `Windows PowerShell`, not `Administrator: Windows PowerShell`.)
- **ac-git-on-path** — `git --version` returns a version string.
- **ac-git-identity** —
  ```powershell
  git config --global user.name   # → Tokuro
  git config --global user.email  # → jonathan.wheeler@witechnologies.org
  ```
- **ac-claude-on-path** — `claude --version` returns a version string.
  Additionally, in a **new** PowerShell window (to verify PATH
  persistence), `claude --version` still works.
- **ac-claude-authed** — `claude auth status` reports authed as
  `jonathan.wheeler@witechnologies.org`.
- **ac-gh-authed-and-credhelper** —
  `gh auth status` shows authenticated on `github.com`, AND
  `gh api user --jq '.login'` returns `tokuro-sedai`, AND
  `git config --get-all credential.https://github.com.helper` output
  contains a line referring to `gh auth git-credential`.
- **ac-extremis-installed** —
  `claude plugin list --json | ConvertFrom-Json | Where-Object { $_.id -like 'extremis@*' }`
  returns at least one result.
- **ac-superpowers-installed** —
  `claude plugin list --json | ConvertFrom-Json | Where-Object { $_.id -like 'superpowers@*' }`
  returns at least one result.
- **ac-arcturus-cloned** —
  `Test-Path C:\source\repos\tokuro-sedai\arcturus\.git` is `True`,
  AND `git -C C:\source\repos\tokuro-sedai\arcturus remote get-url origin`
  resolves to `tokuro-sedai/arcturus` (HTTPS or SSH form both accepted).
- **ac-arcturus-new-window** — the top acceptance test. In a NEW PowerShell
  window, typing `arcturus` cds into `C:\sourceepos	okuro-sedaircturus`
  and starts a signed-in Claude with the extremis and superpowers skills.
  On the VM: `python tests/vm/vmctl.py launch --name accept --script tests/vm/accept-arcturus.ps1 --wait`
  prints `ACCEPT-VERDICT PASS`.

## Fail-Fast

- If the script does not print `ecosystem bootstrap complete.` within
  the timeout, mark the card FAIL without checking the remaining
  criteria.
- If at any point PowerShell displays an ExecutionPolicy error, mark
  FAIL immediately (violates `ac-fetchable-via-irm`).
- If any UAC prompt appears, mark FAIL immediately (violates
  `ac-no-admin-required`).

## Teardown

- Restore the VM to the clean snapshot before running any other
  bootstrap test card. The script has installed global state (PATH,
  user-level configs, plugin cache) that will contaminate subsequent
  clean-state tests.

## Notes

- The `env: clean-win11-vm` reference is to the **Environment** section
  of `docs/testing/README.md`. Any deviation (e.g., Windows 10 host,
  WSL-only environment) invalidates this card.
- This is the highest-coverage card in the suite (12 ACs). Its
  pre-sign-in half also runs unattended as `test-bootstrap-presignin-vm-e2e`. A failure
  on any single bullet is a real defect; it does not mean the card
  is too broad.
