---
name: bootstrap-mid-step-abort
kind: regression
status: draft
timeout: 600
env: clean-win11-vm
covers:
  - ac-failing-step-aborts
---

# Mid-step abort — bootstrap.ps1 fails legibly and stops

Inject a deterministic fault that makes a mid-pipeline step fail, run the
one-liner, and verify the script aborts cleanly: the failing step is
named, no later steps run, the success banner is absent, and the process
exits non-zero.

## Prerequisites

- A Windows 11 VM or host restored to a clean snapshot with no prior
  install of `git`, `claude`, `gh`, `extremis`, or `superpowers`. No
  arcturus checkout anywhere on disk.
- PowerShell 5.1 available (ships with Windows 11).
- `winget` on PATH.
- **Administrator access on the VM is required for this card** — editing
  `C:\Windows\System32\drivers\etc\hosts` requires elevation. The
  bootstrap one-liner itself still runs from a non-elevated PowerShell
  window; only the Setup step needs admin.
- A separate elevated text editor (e.g., `notepad.exe` launched as
  Administrator) for the hosts-file edit.

## Setup

1. Restore the VM to its clean snapshot.
2. Confirm baseline in a non-elevated PowerShell window:
   ```powershell
   Get-Command git, claude, gh -ErrorAction SilentlyContinue
   ```
   Expect: no output. (Step 1 must reach a real `winget install Git.Git`
   so steps 1 and 2 print real status lines before the fault is hit at
   step 3.)
3. Block the Claude installer download by adding a hosts-file entry:
   - Launch `notepad.exe` as Administrator.
   - Open `C:\Windows\System32\drivers\etc\hosts`.
   - Append a new line:
     ```
     127.0.0.1 claude.ai
     ```
   - Save and close.
4. Verify the block from a non-elevated PowerShell window:
   ```powershell
   Resolve-DnsName claude.ai -Type A | Select-Object -First 1 IPAddress
   ```
   Expect: `127.0.0.1`.
5. Close any cached PowerShell sessions; open a fresh **non-elevated**
   PowerShell window for the run.

## Procedure

1. In the non-elevated PowerShell window, paste:
   ```powershell
   irm https://raw.githubusercontent.com/tokuro-sedai/bootstrap/main/bootstrap.ps1 | iex
   ```
2. Wait. Step 1 (`git`) installs via `winget` (this works — winget does
   not go through `claude.ai`). Step 2 (`git config`) sets identity.
   Step 3 (`claude`) attempts `irm https://claude.ai/install.ps1 | iex`,
   which fails because `claude.ai` resolves to `127.0.0.1`.
3. Capture the script's final output and the exit code:
   ```powershell
   $LASTEXITCODE
   ```
   (Or `$?` immediately after the run if `$LASTEXITCODE` is unset by a
   PowerShell-internal `throw`. Either should reflect failure.)

## Pass Criteria

ALL must hold.

- **Steps 1 and 2 status lines present** — output contains lines matching
  `^\[1/8] git\b` and `^\[2/8] git config\b`, each ending in a status
  detail (e.g., `installed`, `set`).
- **Step 3 attempted and failed** — output contains a line beginning
  `[3/8] claude` OR an error message clearly originating from the
  Claude install step (e.g., names `Ensure-Claude`, `claude`, or
  `claude.ai`).
- **Failing step is named in the abort message** — the error text
  identifies the failing step by label or function name. A bare
  PowerShell stack trace with no step identifier is a FAIL.
- **No later steps ran** — output contains NO lines matching any of:
  `^\[4/8]`, `^\[5/8]`, `^\[6/8]`, `^\[7/8]`, `^\[8/8]`.
- **Success banner absent** — the literal line
  `ecosystem bootstrap complete.` does NOT appear anywhere in the output.
- **Non-zero exit** — `$LASTEXITCODE` is non-zero, OR `$?` is `$false`
  immediately after the run. (PowerShell maps an uncaught `throw` to a
  non-zero exit; either signal counts.)

## Fail-Fast

- If `ecosystem bootstrap complete.` appears, mark FAIL immediately
  regardless of any other output.
- If status lines for steps 4 through 8 appear, mark FAIL immediately —
  the script continued past a failing step.
- If the run exits with code 0 (or `$?` is `$true`), mark FAIL
  immediately.

## Teardown

1. Open `C:\Windows\System32\drivers\etc\hosts` in an elevated editor and
   remove the `127.0.0.1 claude.ai` line. Save.
2. Verify:
   ```powershell
   Resolve-DnsName claude.ai -Type A | Select-Object -First 1 IPAddress
   ```
   Expect: a public Anthropic IP, NOT `127.0.0.1`.
3. Restore the VM to its clean snapshot before running any other
   bootstrap test card. The partial run installed `git` and set git
   global identity; later cards that assume a clean baseline will be
   contaminated.

## Notes

- This card requires administrator access for the hosts-file edit only;
  the bootstrap run itself remains non-elevated, preserving the
  `ac-no-admin-required` posture for the script under test.
- A non-admin alternative is to disable the VM's network adapter
  mid-run (after step 2's status line prints, before step 3 starts).
  This is less deterministic — timing-sensitive and may trip step 1
  retry behavior — but is acceptable when admin on the host is
  unavailable. Document which approach was used in the run notes.
- Hosts-file blocking targets `claude.ai` specifically so that `winget`
  (step 1) and any GitHub-hosted resources reached earlier remain
  functional. Blocking `github.com` would fail step 1 before steps 1
  and 2 could establish the "before-failure status lines present"
  evidence this card asserts.
