---
name: bootstrap-no-winget
kind: regression
status: draft
timeout: 120
env: clean-win11-vm
covers:
  - ac-no-winget-aborts-cleanly
---

# No-winget abort — bootstrap.ps1 fails fast at step 1

Run `bootstrap.ps1` on a Windows 11 host where `winget` is not resolvable
on PATH and verify the script aborts at step 1 (Ensure-Git) with a clear
error rather than cascading into later steps.

## Prerequisites

- A Windows 11 VM or host restored to a clean snapshot with no prior
  install of `git`, `claude`, `gh`, `extremis`, or `superpowers`. No
  arcturus checkout anywhere on disk.
- PowerShell 5.1 available (ships with Windows 11).
- `winget` is normally present on the host (ships with Windows 11), but
  this card hides it from the script's session — see Setup.
- Network access to `raw.githubusercontent.com` (the script must still
  download before it can fail).
- The operator is logged into Windows as a **non-administrator** user.

## Setup

1. Restore the VM to its clean snapshot.
2. Open a non-elevated PowerShell window (NOT "Run as Administrator").
3. Confirm baseline:
   ```powershell
   Get-Command git, claude, gh -ErrorAction SilentlyContinue
   ```
   Expect: no output (none of the three should resolve). Step 1 must
   genuinely need `winget` for this card to test the abort path.
4. Hide `winget` from the current session by filtering the
   `WindowsApps` directory out of `$env:PATH`:
   ```powershell
   $env:PATH = ($env:PATH -split ';' |
     Where-Object { $_ -notlike '*\Microsoft\WindowsApps*' }) -join ';'
   ```
5. Verify `winget` is no longer resolvable in this session:
   ```powershell
   Get-Command winget -ErrorAction SilentlyContinue
   ```
   Expect: no output.

## Procedure

1. In the same PowerShell window (with `winget` hidden), paste:
   ```powershell
   irm https://raw.githubusercontent.com/tokuro-sedai/bootstrap/main/bootstrap.ps1 | iex
   ```
2. Observe the output and exit code:
   ```powershell
   $LASTEXITCODE
   ```
   (Or, if `irm | iex` surfaced a terminating error, capture
   `$Error[0]`.)

## Pass Criteria

ALL of the following must hold.

- **Non-zero exit** — The script exited non-zero. Either `$LASTEXITCODE`
  is non-zero, or PowerShell surfaced a terminating exception from the
  script body.
- **Aborted at step 1** — The error message names `winget` as the missing
  prerequisite (e.g., "winget not found", "requires winget", or similar
  legible phrasing). The error is the FIRST failure surfaced; no prior
  step printed a failure.
- **No later steps ran** — The output does NOT contain status lines for
  any step beyond `[1/8]`. Specifically, none of the labels `git config`,
  `claude`, `claude auth`, `gh auth`, `plugin: extremis`,
  `plugin: superpowers`, `arcturus` appear in the output.
- **No install attempts after abort** — No `git`, `claude`, or `gh`
  installation took place. Verify post-run:
  ```powershell
  Get-Command git, claude, gh -ErrorAction SilentlyContinue
  ```
  Expect: still no output. Also verify
  `Test-Path C:\source\repos\tokuro-sedai\arcturus` is `False`.
- **No success banner** — The literal line `ecosystem bootstrap complete.`
  does NOT appear in the output.

## Fail-Fast

- If any later step's status line (any of the labels listed above beyond
  `[1/8]`) appears in the output, mark the card FAIL immediately —
  cascading execution past the missing prerequisite is exactly what this
  card guards against.
- If the script exits zero, mark FAIL immediately.
- If `git`, `claude`, or `gh` is present after the run, mark FAIL —
  something past step 1 must have executed.

## Teardown

1. Revert the PATH manipulation by restoring the original
   `$env:PATH` (closing the PowerShell window is sufficient — the
   `$env:PATH` edit was session-local and not persisted via
   `[Environment]::SetEnvironmentVariable`).
2. Restore the VM to its clean snapshot before running any other
   bootstrap test card.

## Notes

- The `env: clean-win11-vm` reference is to the **Environment** section
  of `docs/testing/README.md`.
- True isolation from a host with `winget` actually removed (e.g., via
  DISM `Remove-AppxPackage` of `Microsoft.DesktopAppInstaller`) is hard
  to set up and to revert. The session-local `$env:PATH` filter used
  here is sufficient to exercise the abort path: the script's probe in
  step 1 resolves `winget` via `Get-Command`, which honours the current
  session's PATH. If a future change makes the script probe `winget` via
  some PATH-independent mechanism (e.g., Appx package query), this card
  must be revisited and a DISM-based teardown approach considered.
- This card is `kind: regression` because its purpose is to guard the
  fail-fast branch from quietly degrading into cascading failures as the
  script evolves.
