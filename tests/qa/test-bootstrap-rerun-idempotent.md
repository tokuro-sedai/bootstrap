---
name: bootstrap-rerun-idempotent
kind: regression
status: draft
timeout: 300
env: clean-win11-vm-with-bootstrap-applied
covers:
  - ac-rerun-is-noop
  - ac-setup-git-idempotent
---

# Re-run idempotency — bootstrap.ps1 on a provisioned machine

Re-run the one-liner on a Windows 11 host that has already been
bootstrapped successfully. Verify that every probe-satisfied step
reports "already satisfied" with no side effects, that the arcturus
step performs only a `git pull`, and that `gh auth setup-git` does
not duplicate the `github.com` credential helper line.

## Prerequisites

- A Windows 11 VM restored to a snapshot taken **after** a successful
  end-to-end run of `test-bootstrap-fresh-vm-smoke.md`. All eight
  post-conditions of that card must already hold:
  - `git`, `claude`, `gh` resolvable on PATH.
  - Global git identity set to `Tokuro` /
    `jonathan.wheeler@witechnologies.org`.
  - Claude authed as `jonathan.wheeler@lifemaideasier.com`.
  - `gh` authed on `github.com` with `tokuro-sedai` org access; git
    credential helper configured.
  - `extremis` and `superpowers` plugins installed.
  - `C:\source\repos\tokuro-sedai\arcturus` is a git work tree whose
    origin is `tokuro-sedai/arcturus`.
- PowerShell 5.1 available, `winget` on PATH, network access to
  `github.com`, `raw.githubusercontent.com`, `claude.ai`.
- The operator is logged in as a non-administrator user.
- No browser OAuth re-entry is expected — both Claude and `gh` should
  remain authed from the snapshot.

## Setup

1. Restore the VM to the post-bootstrap snapshot.
2. Open a non-elevated PowerShell window.
3. Record baseline state for the diff-after-rerun comparison:
   ```powershell
   git config --get-all credential.https://github.com.helper |
     Set-Content $env:TEMP\baseline-credhelper.txt
   git -C C:\source\repos\tokuro-sedai\arcturus rev-parse HEAD |
     Set-Content $env:TEMP\baseline-arcturus-head.txt
   git config --global user.name  | Set-Content $env:TEMP\baseline-name.txt
   git config --global user.email | Set-Content $env:TEMP\baseline-email.txt
   ```
4. Confirm the baseline credential helper file contains exactly one
   line referring to `gh auth git-credential`. If it already contains
   more than one such line, the snapshot is invalid for this card —
   stop and rebuild the snapshot.

## Procedure

1. In the same PowerShell window, paste:
   ```powershell
   irm https://raw.githubusercontent.com/tokuro-sedai/bootstrap/main/bootstrap.ps1 | iex
   ```
2. Do **not** complete any browser OAuth flow — none should appear.
   If a browser opens for `claude auth login` or `gh auth login`,
   that is an immediate fail (see Fail-Fast).
3. Wait for the script to print `ecosystem bootstrap complete.` and
   return to the prompt with exit code 0
   (`$LASTEXITCODE -eq 0` or, for non-native PowerShell errors,
   `$?` is `True`).

## Pass Criteria

Each bullet is independently verifiable. ALL must pass.

- **ac-rerun-is-noop** — Steps 1 through 7 each emit a status line
  containing the literal text `already satisfied`. Step 8
  (`arcturus`) emits a status line containing either
  `already up to date` or `pulled` (the latter only if upstream
  advanced between snapshot and re-run). Verify:
  ```powershell
  # Re-capture state and diff against baseline.
  git config --global user.name  |
    Compare-Object - (Get-Content $env:TEMP\baseline-name.txt)
  git config --global user.email |
    Compare-Object - (Get-Content $env:TEMP\baseline-email.txt)
  ```
  Both `Compare-Object` calls must produce no output (no
  side effects on git identity). The script's stdout transcript
  must contain exactly eight `[N/8] ...` status lines and end with
  `ecosystem bootstrap complete.`. No `installed`, `set`, `changed`,
  or `re-authed` detail tokens appear on lines 1–7.
- **ac-setup-git-idempotent** — Re-running the script does not
  duplicate or corrupt the `github.com` credential helper:
  ```powershell
  $helpers = git config --get-all credential.https://github.com.helper
  $helpers | Should -HaveCount 1   # exactly one configured helper
  $helpers | Should -Match 'gh auth git-credential'
  Compare-Object `
    (Get-Content $env:TEMP\baseline-credhelper.txt) `
    $helpers
  ```
  The line count must be exactly 1; the single line must contain
  `gh auth git-credential`; and `Compare-Object` against the
  pre-rerun baseline must produce no output (the file is byte-for-byte
  unchanged). If `Should` is unavailable, the equivalent assertion is:
  `(@($helpers)).Count -eq 1 -and $helpers -match 'gh auth git-credential'`.

## Fail-Fast

- If a browser opens for `claude auth login` or `gh auth login`, mark
  FAIL immediately — the snapshot's auth state did not survive, or
  the probe logic is wrong.
- If any step prints `installed`, `set`, `changed`, or any token other
  than `already satisfied` (excluding step 8's `arcturus` line), mark
  FAIL — a probe is incorrectly reporting unsatisfied state.
- If `git config --get-all credential.https://github.com.helper`
  returns more than one line, mark FAIL — `gh auth setup-git` is
  appending instead of being idempotent.
- If the script does not print `ecosystem bootstrap complete.` within
  the timeout, or exits non-zero, mark FAIL.

## Teardown

- Restore the VM to the post-bootstrap snapshot before running any
  other test card. (For cards that need a clean-Win11 baseline, use
  the pristine snapshot from `test-bootstrap-fresh-vm-smoke.md`
  instead.)
- Discard the `$env:TEMP\baseline-*.txt` capture files; they are
  scratch state for this card only.

## Notes

- The `env: clean-win11-vm-with-bootstrap-applied` is an inline
  reference: it means the **Environment** section of
  `docs/testing/README.md` plus the additional pre-condition that
  `test-bootstrap-fresh-vm-smoke.md` has been executed successfully
  and snapshotted.
- This card is `kind: regression` because it guards specifically
  against two regressions implied by the design: (a) a probe that
  forgets to short-circuit and re-installs on every run, and (b)
  `gh auth setup-git` being invoked unconditionally without
  verifying that the resulting helper config remains a single line.
- Step 8's accepted detail strings (`already up to date` /
  `pulled N new commits`) match the format shown in the design's
  Output Format section.
