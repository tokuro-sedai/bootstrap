---
name: bootstrap-arcturus-path-collision
kind: regression
status: draft
timeout: 900
env: clean-win11-vm
covers:
  - ac-arcturus-path-collision
---

# Path collision — bootstrap.ps1 refuses to touch a foreign arcturus path

Run `bootstrap.ps1` against a host where
`C:\source\repos\tokuro-sedai\arcturus` already exists but is NOT a
`tokuro-sedai/arcturus` checkout. Step 8 must abort with a "refusing to
touch" error and leave the existing directory bit-for-bit unchanged.

## Prerequisites

- A Windows 11 VM or host restored to a clean snapshot.
- PowerShell 5.1 (ships with Windows 11).
- `winget` on PATH.
- Network access to `github.com`, `raw.githubusercontent.com`, and
  `claude.ai`.
- `git` is already installed and on PATH (needed by Setup to seed the
  collision). If the snapshot does not include git, install it via
  `winget install --id Git.Git -e --silent` before Setup so the seed step
  can clone the decoy.
- QA operator has credentials to log into:
  - `jonathan.wheeler@lifemaideasier.com` (Claude) via OAuth in a
    browser.
  - `jonathan.wheeler@witechnologies.org` with `tokuro-sedai` org
    access (GitHub) via OAuth in a browser.
- The operator is logged into Windows as a **non-administrator** user.

## Setup

1. Restore the VM to its clean snapshot.
2. Open a non-elevated PowerShell window (NOT "Run as Administrator").
3. Confirm `C:\source\repos\tokuro-sedai\arcturus` does not exist:
   ```powershell
   Test-Path C:\source\repos\tokuro-sedai\arcturus  # → False
   ```
4. Seed the collision by cloning an unrelated repo into the target path:
   ```powershell
   New-Item -ItemType Directory -Force -Path C:\source\repos\tokuro-sedai | Out-Null
   git clone https://github.com/octocat/Hello-World C:\source\repos\tokuro-sedai\arcturus
   ```
   Confirm the decoy is in place and is NOT a `tokuro-sedai/arcturus`
   checkout:
   ```powershell
   git -C C:\source\repos\tokuro-sedai\arcturus remote get-url origin
   # → https://github.com/octocat/Hello-World(.git)
   ```
5. Record a pre-run fingerprint of the directory tree (this is the
   evidence that the directory was NOT modified):
   ```powershell
   $before = Get-ChildItem -Recurse -Force C:\source\repos\tokuro-sedai\arcturus |
       Sort-Object FullName |
       ForEach-Object {
           if ($_.PSIsContainer) {
               "$($_.FullName)`tDIR"
           } else {
               "$($_.FullName)`t$($_.Length)`t$((Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash)"
           }
       }
   $before | Set-Content -Encoding UTF8 -Path "$env:TEMP\arcturus-before.txt"
   ```

## Procedure

1. In the same PowerShell window, paste:
   ```powershell
   irm https://raw.githubusercontent.com/tokuro-sedai/bootstrap/main/bootstrap.ps1 | iex
   ```
2. When `claude auth login` opens a browser, complete OAuth as
   `jonathan.wheeler@lifemaideasier.com`.
3. When `gh auth login` prompts and opens a browser, complete OAuth as
   `jonathan.wheeler@witechnologies.org`.
4. Allow steps 1–7 to run normally; step 8 is the one under test.
5. Capture the script's exit code immediately after it returns:
   ```powershell
   $exitCode = $LASTEXITCODE
   ```
6. Compute a post-run fingerprint of the directory tree using the same
   recipe as Setup step 5, into `$env:TEMP\arcturus-after.txt`.

## Pass Criteria

ALL bullets must hold.

- **Non-zero exit** — `$exitCode` is non-zero (PowerShell `throw`
  surfaces as a failure exit code from the `irm | iex` invocation).
- **"Refusing to touch" error** — The script's terminal output includes
  the literal phrase `refusing to touch` (case-insensitive) in the
  step-8 error, and the error names `arcturus` (or
  `tokuro-sedai/arcturus`) and the offending path
  `C:\source\repos\tokuro-sedai\arcturus`.
- **Step 8 attributed** — The failing status line is the step-8 line
  (matches `^\[8/8\] `). No status line for a step beyond `[8/8]` is
  printed (there is none in the design, but a stray line would indicate
  the abort was not clean).
- **Success banner absent** — The literal line `ecosystem bootstrap
  complete.` does NOT appear anywhere in the run's output.
- **Directory bit-for-bit unchanged** — The pre- and post-run
  fingerprint files are identical:
  ```powershell
  Compare-Object (Get-Content "$env:TEMP\arcturus-before.txt") `
                 (Get-Content "$env:TEMP\arcturus-after.txt")
  ```
  must produce no output. Equivalently, every file's size and SHA-256
  match, and the set of paths (files + directories) is identical.
- **Decoy origin still points at the unrelated repo** —
  `git -C C:\source\repos\tokuro-sedai\arcturus remote get-url origin`
  still resolves to the Hello-World URL recorded in Setup step 4. The
  script did not rewrite `.git/config`.

## Fail-Fast

- If `Compare-Object` reports ANY difference between the pre- and
  post-run fingerprint files — even a single file added, removed,
  modified, or re-hashed — mark the card FAIL immediately. The whole
  point of the AC is that the script does not mutate user data on a
  collision.
- If the script's output contains `ecosystem bootstrap complete.`, mark
  FAIL: step 8 silently accepted the foreign checkout instead of
  aborting.
- If the error message is missing the phrase `refusing to touch` (or an
  obvious paraphrase that still names the path and refuses the action),
  mark FAIL: the AC requires a *legible* abort, not just any throw.
- If the script's exit code is `0`, mark FAIL.

## Teardown

- Delete the seeded decoy and the fingerprint files:
  ```powershell
  Remove-Item -Recurse -Force C:\source\repos\tokuro-sedai\arcturus
  Remove-Item "$env:TEMP\arcturus-before.txt", "$env:TEMP\arcturus-after.txt" -ErrorAction SilentlyContinue
  ```
- Restore the VM to its clean snapshot before running any other
  bootstrap test card. Steps 1–7 ran to completion in this card and
  installed global state (PATH, plugin cache, gh/claude auth) that will
  contaminate subsequent clean-state tests.

## Notes

- The `env: clean-win11-vm` reference is to the **Environment** section
  of `docs/testing/README.md`. The seeded decoy is a deliberate
  deviation from "no arcturus checkout anywhere on disk" and is the
  whole point of this card; do not treat that as an env mismatch.
- `octocat/Hello-World` is chosen as the decoy because it is small,
  public (no auth needed to clone), and unmistakably not
  `tokuro-sedai/arcturus`. Any other small public repo would do.
- This card runs steps 1–7 in full — including the two interactive
  OAuth prompts — because step 8's probe depends on `git` (step 1) and
  the script is a linear sequence. A future enhancement could expose a
  `-OnlyStep 8` switch to make this card cheaper, but that is out of
  scope for the design as written.
- The fingerprint approach (path + size + SHA-256 of every file) is
  stricter than a simple file-count check: it catches in-place edits,
  permission changes that alter content hashes, and re-cloned
  `.git/objects` packs.
