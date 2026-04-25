# Ecosystem Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce `bootstrap.ps1` at the root of `tokuro-sedai/bootstrap`, satisfying all 18 ACs in `docs/superpowers/specs/2026-04-24-ecosystem-bootstrap-design.md` and pass-criteria in the 7 QA cards under `tests/qa/`.

**Architecture:** Single PowerShell 5.1 script. Eight idempotent `Ensure-*` functions plus three small print/path helpers. Fail-fast (`Set-StrictMode -Version Latest` + `$ErrorActionPreference = 'Stop'`). Main body invokes the eight functions in order, prints one status line per step, ends with `ecosystem bootstrap complete.` on success. PowerShell's default behaviour of throwing on unhandled errors gives a non-zero exit code on failure.

**Tech Stack:** PowerShell 5.1, `winget`, the native Claude Code installer (`irm https://claude.ai/install.ps1 | iex`), `gh` CLI, `claude plugin` CLI.

**Branch / commit policy:** Solo repo, fresh `main` branch. Commit each task directly to `main` unless the executor prefers a feature branch. Each task ends with one commit.

**Per-task verification on the developer machine:** This developer machine (the one running the plan) already has a complete ecosystem (git, claude, gh, plugins, arcturus checkout). After each task, dot-sourcing the script and invoking the new function should print "already satisfied" — that confirms the probe is correct. The fix-path is verified by the QA cards on a fresh Windows 11 VM, executed in the run-test-cases phase.

---

## File Structure

- Create: `bootstrap.ps1` (repo root)

The script grows incrementally across the tasks. By the end its skeleton is:

```
#Requires -Version 5.1
<# Synopsis comment block #>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Module-level constants (expected identities, target paths)

# Print/path helpers (3 functions)

# Eight Ensure-* functions

# Main()

Main
```

No subdirectories or auxiliary files. The repo's `tests/qa/` and `docs/` already exist.

---

## Task 1: Scaffold script header + module-level constants

**Files:**
- Create: `bootstrap.ps1`

- [ ] **Step 1: Write the script header and constants**

```powershell
#Requires -Version 5.1
<#
.SYNOPSIS
    Bootstrap a fresh Windows 11 machine for the Claude + arcturus ecosystem.

.DESCRIPTION
    Eight idempotent steps. See README.md and the design spec at
    docs/superpowers/specs/2026-04-24-ecosystem-bootstrap-design.md.

.NOTES
    Delivered via `irm | iex`. ExecutionPolicy does not apply because the
    script is piped through Invoke-Expression rather than loaded from disk.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- expected identities and target paths --------------------------------

$Script:ExpectedClaudeEmail = 'jonathan.wheeler@lifemaideasier.com'
$Script:ExpectedGitName     = 'Tokuro'
$Script:ExpectedGitEmail    = 'jonathan.wheeler@witechnologies.org'
$Script:ArcturusRepo        = 'tokuro-sedai/arcturus'
$Script:ArcturusTargetPath  = 'C:\source\repos\tokuro-sedai\arcturus'
$Script:ExtremisMarketplace = 'tokuro-sedai/extremis'
$Script:SuperpowersMarketplace = 'obra/superpowers-marketplace'
$Script:ClaudeBinDir        = Join-Path $env:USERPROFILE '.local\bin'

# --- step counter (set by Main; used by Write-StepHeader) ---------------

$Script:StepCount = 8
$Script:StepIndex = 0
```

- [ ] **Step 2: Verify the script parses**

Run from the repo root:

```powershell
powershell.exe -NoProfile -Command "& { . .\bootstrap.ps1 }"
```

Expected: exits 0 with no output (file is parseable but defines no callable functions yet).

- [ ] **Step 3: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat: scaffold bootstrap.ps1 with strict-mode header and constants"
```

---

## Task 2: Print/path helpers

**Files:**
- Modify: `bootstrap.ps1` (append after the constants block)

- [ ] **Step 1: Write the three helpers**

Append to `bootstrap.ps1`:

```powershell
# --- print helpers -------------------------------------------------------

function Write-StepHeader {
    param([Parameter(Mandatory)][string]$Label)
    $Script:StepIndex++
    $tag = "[{0}/{1}] {2,-22}" -f $Script:StepIndex, $Script:StepCount, $Label
    Write-Host -NoNewline "$tag ..."
}

function Write-StepStatus {
    param(
        [Parameter(Mandatory)][ValidateSet('skipped','changed','failed')][string]$Status,
        [Parameter(Mandatory)][string]$Detail
    )
    $word = switch ($Status) {
        'skipped' { 'already satisfied' }
        'changed' { 'changed' }
        'failed'  { 'FAILED' }
    }
    $color = switch ($Status) {
        'skipped' { 'DarkGray' }
        'changed' { 'Green'    }
        'failed'  { 'Red'      }
    }
    Write-Host " $word ($Detail)" -ForegroundColor $color
}

# --- PATH refresh --------------------------------------------------------

function Update-EnvPath {
    # Refresh the in-process PATH from User + Machine env so newly-installed
    # binaries are discoverable in this session.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:PATH = ($machine, $user | Where-Object { $_ } ) -join ';'
}
```

- [ ] **Step 2: Verify the helpers in isolation**

Open a fresh PowerShell, dot-source the script (it doesn't execute Main yet), then invoke:

```powershell
. .\bootstrap.ps1
Write-StepHeader -Label 'demo'
Write-StepStatus -Status skipped -Detail 'sanity'
```

Expected: `[1/8] demo                   ... already satisfied (sanity)` printed in dark-gray.

- [ ] **Step 3: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat: add Write-StepHeader / Write-StepStatus / Update-EnvPath helpers"
```

---

## Task 3: Ensure-Git function

**Files:**
- Modify: `bootstrap.ps1` (append after helpers)

- [ ] **Step 1: Write the function**

```powershell
# --- step 1: ensure git --------------------------------------------------

function Ensure-Git {
    Write-StepHeader -Label 'git'

    $cmd = Get-Command git -ErrorAction SilentlyContinue
    if ($cmd) {
        $version = (& git --version) -replace '^git version ', ''
        Write-StepStatus -Status skipped -Detail "git $version"
        return
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "git is missing and winget is not available — cannot install. Install winget (Windows 11 App Installer) and re-run."
    }

    & winget install --id Git.Git -e --source winget --silent --accept-source-agreements --accept-package-agreements | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "winget install Git.Git failed with exit code $LASTEXITCODE"
    }

    Update-EnvPath

    $cmd = Get-Command git -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Ensure-Git post-check failed: git still not on PATH after install."
    }

    $version = (& git --version) -replace '^git version ', ''
    Write-StepStatus -Status changed -Detail "installed git $version"
}
```

- [ ] **Step 2: Verify against this developer machine**

The developer machine has git installed, so this should hit the early-return "already satisfied" path:

```powershell
. .\bootstrap.ps1
$Script:StepIndex = 0
Ensure-Git
```

Expected: `[1/8] git                    ... already satisfied (git X.Y.Z)`.

- [ ] **Step 3: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat: implement Ensure-Git (probe + winget install)"
```

---

## Task 4: Ensure-GitConfig function

**Files:**
- Modify: `bootstrap.ps1` (append after Ensure-Git)

- [ ] **Step 1: Write the function**

```powershell
# --- step 2: ensure git config (global identity) -------------------------

function Ensure-GitConfig {
    Write-StepHeader -Label 'git config'

    $currentName  = (& git config --global user.name)  2>$null
    $currentEmail = (& git config --global user.email) 2>$null

    if ($currentName -eq $Script:ExpectedGitName -and $currentEmail -eq $Script:ExpectedGitEmail) {
        Write-StepStatus -Status skipped -Detail "$currentName <$currentEmail>"
        return
    }

    & git config --global user.name  $Script:ExpectedGitName
    & git config --global user.email $Script:ExpectedGitEmail

    $afterName  = (& git config --global user.name)  2>$null
    $afterEmail = (& git config --global user.email) 2>$null
    if ($afterName -ne $Script:ExpectedGitName -or $afterEmail -ne $Script:ExpectedGitEmail) {
        throw "Ensure-GitConfig post-check failed: name='$afterName' email='$afterEmail'"
    }

    Write-StepStatus -Status changed -Detail "set ($afterName <$afterEmail>)"
}
```

- [ ] **Step 2: Verify against this developer machine**

This machine currently has no global identity (per earlier session check — commits use per-commit overrides). So this run will SET the identity. That's OK for this developer flow.

```powershell
. .\bootstrap.ps1
$Script:StepIndex = 1   # so the header prints [2/8]
Ensure-GitConfig
```

Expected: either `... already satisfied (Tokuro <jonathan.wheeler@witechnologies.org>)` (if previously set) or `... changed (set (Tokuro <jonathan.wheeler@witechnologies.org>))`. Either is fine — second invocation must print "already satisfied".

Re-run to confirm idempotency:

```powershell
$Script:StepIndex = 1
Ensure-GitConfig
```

Expected: `... already satisfied (...)`.

- [ ] **Step 3: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat: implement Ensure-GitConfig with idempotent set"
```

---

## Task 5: Ensure-Claude function (install + persist user PATH)

**Files:**
- Modify: `bootstrap.ps1`

- [ ] **Step 1: Write the function**

```powershell
# --- step 3: ensure claude (install + persist user PATH) -----------------

function Add-DirToUserPath {
    param([Parameter(Mandatory)][string]$Dir)
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $segments = if ($userPath) { $userPath -split ';' } else { @() }
    if ($segments -notcontains $Dir) {
        $segments += $Dir
        [Environment]::SetEnvironmentVariable('Path', ($segments -join ';'), 'User')
    }
}

function Ensure-Claude {
    Write-StepHeader -Label 'claude'

    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($cmd) {
        $version = (& claude --version 2>$null) -replace '^.*?(\d[\d.]*\S*).*$', '$1'
        Write-StepStatus -Status skipped -Detail "claude $version"
        return
    }

    Invoke-RestMethod 'https://claude.ai/install.ps1' | Invoke-Expression

    Add-DirToUserPath -Dir $Script:ClaudeBinDir
    Update-EnvPath

    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Ensure-Claude post-check failed: claude still not on PATH after install. Looked in user PATH for $Script:ClaudeBinDir."
    }

    $version = (& claude --version 2>$null) -replace '^.*?(\d[\d.]*\S*).*$', '$1'
    Write-StepStatus -Status changed -Detail "installed claude $version, added $Script:ClaudeBinDir to user PATH"
}
```

- [ ] **Step 2: Verify against this developer machine**

```powershell
. .\bootstrap.ps1
$Script:StepIndex = 2
Ensure-Claude
```

Expected: `[3/8] claude                 ... already satisfied (claude X.Y.Z)`. The version-extraction regex may need adjustment based on what `claude --version` prints — verify the printed string is non-empty.

If the version comes out blank or weird, add a fallback:

```powershell
$rawVersion = (& claude --version 2>$null)
$version = if ($rawVersion) { $rawVersion.Trim() } else { 'installed' }
```

Use whichever produces a clean line.

- [ ] **Step 3: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat: implement Ensure-Claude (native installer + persist user PATH)"
```

---

## Task 6: Ensure-ClaudeAuth function

**Files:**
- Modify: `bootstrap.ps1`

- [ ] **Step 1: Write the function**

```powershell
# --- step 4: ensure claude auth ------------------------------------------

function Get-ClaudeAuthedEmail {
    # Returns the authed email or $null. Parsing is implementation-specific
    # and may need to be adjusted if `claude auth status` output changes.
    $output = & claude auth status 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    $line = $output | Where-Object { $_ -match '[\w._%+-]+@[\w.-]+\.\w+' } | Select-Object -First 1
    if (-not $line) { return $null }
    if ($line -match '([\w._%+-]+@[\w.-]+\.\w+)') { return $Matches[1] }
    return $null
}

function Ensure-ClaudeAuth {
    Write-StepHeader -Label 'claude auth'

    $email = Get-ClaudeAuthedEmail
    if ($email -eq $Script:ExpectedClaudeEmail) {
        Write-StepStatus -Status skipped -Detail $email
        return
    }

    if ($email -and $email -ne $Script:ExpectedClaudeEmail) {
        Write-Host ""
        Write-Host "  Claude is currently authed as $email; expected $Script:ExpectedClaudeEmail. Logging out..." -ForegroundColor Yellow
        & claude auth logout 2>&1 | Out-Null
    }

    Write-Host ""
    Write-Host "  Launching 'claude auth login'. Complete the browser flow as $Script:ExpectedClaudeEmail." -ForegroundColor Yellow
    & claude auth login

    $after = Get-ClaudeAuthedEmail
    if ($after -ne $Script:ExpectedClaudeEmail) {
        throw "Ensure-ClaudeAuth post-check failed: authed as '$after', expected '$Script:ExpectedClaudeEmail'."
    }

    Write-StepStatus -Status changed -Detail "authed as $after"
}
```

- [ ] **Step 2: Verify against this developer machine**

```powershell
. .\bootstrap.ps1
$Script:StepIndex = 3
Ensure-ClaudeAuth
```

Expected: `[4/8] claude auth            ... already satisfied (jonathan.wheeler@lifemaideasier.com)`.

If `Get-ClaudeAuthedEmail` returns `$null` despite the user being authed, the parsing is wrong. Run `claude auth status` standalone to see the actual output and adjust the regex / line-selection.

- [ ] **Step 3: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat: implement Ensure-ClaudeAuth with verify-and-re-auth policy"
```

---

## Task 7: Ensure-GhAuth function

**Files:**
- Modify: `bootstrap.ps1`

- [ ] **Step 1: Write the function**

```powershell
# --- step 5: ensure gh auth + git credential helper ----------------------

function Test-GhAuthOk {
    & gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }

    $orgs = & gh api 'user/orgs' --jq '.[].login' 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    return ($orgs -split "`n") -contains 'tokuro-sedai'
}

function Test-GhCredHelperOk {
    $helper = & git config --get-all 'credential.https://github.com.helper' 2>$null
    if (-not $helper) { return $false }
    return ($helper | Out-String) -match 'gh\b.*auth\b.*git-credential'
}

function Ensure-GhAuth {
    Write-StepHeader -Label 'gh auth'

    $authOk   = Test-GhAuthOk
    $helperOk = Test-GhCredHelperOk

    if ($authOk -and $helperOk) {
        Write-StepStatus -Status skipped -Detail 'authed + credential helper wired'
        return
    }

    if (-not $authOk) {
        Write-Host ""
        Write-Host "  Launching 'gh auth login'. Complete the browser flow as the tokuro-sedai-org account." -ForegroundColor Yellow
        & gh auth login --web --hostname github.com --git-protocol https
        if ($LASTEXITCODE -ne 0) {
            throw "gh auth login exited with $LASTEXITCODE"
        }
    }

    # Always run setup-git: idempotent and ensures the helper is wired
    # regardless of how the user answered the inline prompt.
    & gh auth setup-git --hostname github.com
    if ($LASTEXITCODE -ne 0) {
        throw "gh auth setup-git --hostname github.com exited with $LASTEXITCODE"
    }

    if (-not (Test-GhAuthOk)) {
        throw "Ensure-GhAuth post-check failed: gh not authenticated or tokuro-sedai org not visible."
    }
    if (-not (Test-GhCredHelperOk)) {
        throw "Ensure-GhAuth post-check failed: git credential helper for github.com is not configured to use gh."
    }

    Write-StepStatus -Status changed -Detail 'authed + credential helper wired'
}
```

- [ ] **Step 2: Verify against this developer machine**

```powershell
. .\bootstrap.ps1
$Script:StepIndex = 4
Ensure-GhAuth
```

Expected: `[5/8] gh auth                ... already satisfied (authed + credential helper wired)`.

NOTE: this developer machine does NOT currently have the gh credential helper wired (per earlier session — `git config --get-all credential.https://github.com.helper` returned only `manager`). Running this will fix that. That's expected — it's the function doing its job. Re-run to confirm idempotency:

```powershell
$Script:StepIndex = 4
Ensure-GhAuth
```

Second invocation must print "already satisfied".

If `gh api 'user/orgs'` is mangled by Git Bash path-rewriting (observed earlier), it will work fine in pure PowerShell.

- [ ] **Step 3: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat: implement Ensure-GhAuth (auth + idempotent setup-git)"
```

---

## Task 8: Ensure-Plugin parameterised helper

**Files:**
- Modify: `bootstrap.ps1`

- [ ] **Step 1: Write the helper**

```powershell
# --- plugin helper (used by steps 6 and 7) -------------------------------

function Ensure-Plugin {
    param(
        [Parameter(Mandatory)][string]$PluginName,
        [Parameter(Mandatory)][string]$MarketplaceRepo,
        [Parameter(Mandatory)][string]$PluginSpec,
        [Parameter(Mandatory)][string]$StepLabel
    )

    Write-StepHeader -Label $StepLabel

    $installed = & claude plugin list --json 2>$null | ConvertFrom-Json
    $existing  = $installed | Where-Object { $_.id -like "$PluginName@*" } | Select-Object -First 1

    if ($existing) {
        Write-StepStatus -Status skipped -Detail $existing.id
        return
    }

    & claude plugin marketplace add $MarketplaceRepo 2>&1 | Out-Null
    # Marketplace add may exit non-zero if already added; that's OK.

    & claude plugin install $PluginSpec --scope user
    if ($LASTEXITCODE -ne 0) {
        throw "claude plugin install $PluginSpec exited with $LASTEXITCODE"
    }

    $installed = & claude plugin list --json 2>$null | ConvertFrom-Json
    $after = $installed | Where-Object { $_.id -like "$PluginName@*" } | Select-Object -First 1
    if (-not $after) {
        throw "Ensure-Plugin post-check failed: $PluginName not present in plugin list after install."
    }

    Write-StepStatus -Status changed -Detail "installed $($after.id)"
}
```

- [ ] **Step 2: Verify the helper is callable**

The helper isn't called yet at module level. Just check the script still parses:

```powershell
. .\bootstrap.ps1
Get-Command Ensure-Plugin
```

Expected: command is defined.

- [ ] **Step 3: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat: implement Ensure-Plugin parameterised helper"
```

---

## Task 9: Ensure-Plugin invocations for extremis and superpowers

These two are not separate top-level functions; they are calls to `Ensure-Plugin` from `Main` (added in Task 11). Here we do *not* yet add code — we only verify the helper works against the live machine state. Both plugins are already installed on this developer machine, so the calls return "already satisfied".

**Files:**
- (none — verification only; no commit required for this task)

- [ ] **Step 1: Verify Ensure-Plugin against extremis**

```powershell
. .\bootstrap.ps1
$Script:StepIndex = 5
Ensure-Plugin -PluginName 'extremis' `
              -MarketplaceRepo 'tokuro-sedai/extremis' `
              -PluginSpec 'extremis@extremis' `
              -StepLabel 'plugin: extremis'
```

Expected: `[6/8] plugin: extremis       ... already satisfied (extremis@extremis)`.

- [ ] **Step 2: Verify Ensure-Plugin against superpowers**

```powershell
$Script:StepIndex = 6
Ensure-Plugin -PluginName 'superpowers' `
              -MarketplaceRepo 'obra/superpowers-marketplace' `
              -PluginSpec 'superpowers@superpowers-marketplace' `
              -StepLabel 'plugin: superpowers'
```

Expected: `[7/8] plugin: superpowers    ... already satisfied (superpowers@<marketplace>)`. Marketplace may resolve to either `obra/superpowers-marketplace` or `claude-plugins-official` — both satisfy the wildcard probe.

- [ ] **Step 3: No commit for this task** (verification only).

---

## Task 10: Ensure-Arcturus function

**Files:**
- Modify: `bootstrap.ps1`

- [ ] **Step 1: Write the function**

```powershell
# --- step 8: ensure arcturus checkout ------------------------------------

function Test-ArcturusOriginMatches {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path (Join-Path $Path '.git'))) { return $false }
    $url = & git -C $Path remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $url) { return $false }
    return $url -match 'tokuro-sedai/arcturus(\.git)?$'
}

function Ensure-Arcturus {
    Write-StepHeader -Label 'arcturus'

    $target = $Script:ArcturusTargetPath

    if (Test-Path $target) {
        if (-not (Test-ArcturusOriginMatches -Path $target)) {
            throw "Ensure-Arcturus: '$target' exists but is not a tokuro-sedai/arcturus checkout — refusing to touch."
        }
        $before = (& git -C $target rev-parse HEAD).Trim()
        & git -C $target pull --ff-only 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "git -C $target pull --ff-only exited with $LASTEXITCODE"
        }
        $after = (& git -C $target rev-parse HEAD).Trim()
        if ($before -eq $after) {
            Write-StepStatus -Status skipped -Detail "up to date at $target"
        } else {
            $count = (& git -C $target rev-list --count "$before..$after").Trim()
            Write-StepStatus -Status changed -Detail "pulled, $count new commit(s) at $target"
        }
        return
    }

    $parent = Split-Path $target -Parent
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    & gh repo clone $Script:ArcturusRepo $target
    if ($LASTEXITCODE -ne 0) {
        throw "gh repo clone $Script:ArcturusRepo $target exited with $LASTEXITCODE"
    }

    if (-not (Test-ArcturusOriginMatches -Path $target)) {
        throw "Ensure-Arcturus post-check failed: $target is not a valid arcturus checkout."
    }

    Write-StepStatus -Status changed -Detail "cloned to $target"
}
```

- [ ] **Step 2: Verify against this developer machine**

The arcturus checkout is at the canonical path on this machine.

```powershell
. .\bootstrap.ps1
$Script:StepIndex = 7
Ensure-Arcturus
```

Expected: `[8/8] arcturus               ... already satisfied (up to date at C:\source\repos\tokuro-sedai\arcturus)` OR `... changed (pulled, N new commit(s)...)`.

If something has been committed remotely since the last pull, the changed branch fires; that's fine.

- [ ] **Step 3: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat: implement Ensure-Arcturus (clone-or-pull with refusal on collision)"
```

---

## Task 11: Main and final invocation

**Files:**
- Modify: `bootstrap.ps1`

- [ ] **Step 1: Add the Main function and the unconditional bottom call**

Append to `bootstrap.ps1`:

```powershell
# --- main ---------------------------------------------------------------

function Main {
    $Script:StepIndex = 0

    Ensure-Git
    Ensure-GitConfig
    Ensure-Claude
    Ensure-ClaudeAuth
    Ensure-GhAuth
    Ensure-Plugin -PluginName 'extremis' `
                  -MarketplaceRepo $Script:ExtremisMarketplace `
                  -PluginSpec 'extremis@extremis' `
                  -StepLabel 'plugin: extremis'
    Ensure-Plugin -PluginName 'superpowers' `
                  -MarketplaceRepo $Script:SuperpowersMarketplace `
                  -PluginSpec 'superpowers@superpowers-marketplace' `
                  -StepLabel 'plugin: superpowers'
    Ensure-Arcturus

    Write-Host ""
    Write-Host "ecosystem bootstrap complete." -ForegroundColor Green
}

Main
```

- [ ] **Step 2: Run the full script end-to-end on this developer machine**

```powershell
.\bootstrap.ps1
```

Expected output (each line printed in dark-gray for "already satisfied" or green for "changed"):

```
[1/8] git                    ... already satisfied (git X.Y.Z)
[2/8] git config             ... already satisfied (Tokuro <jonathan.wheeler@witechnologies.org>)
[3/8] claude                 ... already satisfied (claude X.Y.Z)
[4/8] claude auth            ... already satisfied (jonathan.wheeler@lifemaideasier.com)
[5/8] gh auth                ... already satisfied (authed + credential helper wired)
[6/8] plugin: extremis       ... already satisfied (extremis@extremis)
[7/8] plugin: superpowers    ... already satisfied (superpowers@<marketplace>)
[8/8] arcturus               ... already satisfied (up to date at C:\source\repos\tokuro-sedai\arcturus)

ecosystem bootstrap complete.
```

If any step prints `changed (...)` instead of `already satisfied`, that's still a passing run — it just means the machine wasn't already in the target state and the function fixed it. Re-run; the second run must be all "already satisfied" except possibly arcturus pulling.

If the script throws at any point, fix that step's function and re-run.

- [ ] **Step 3: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat: add Main and run all eight Ensure-* steps"
```

---

## Task 12: Dry-run via the irm-pipe-iex delivery path

**Files:**
- (none — final integration check)

- [ ] **Step 1: Push current state to origin**

```bash
git push origin main
```

- [ ] **Step 2: Verify the script works when fetched and piped**

In a new PowerShell window:

```powershell
irm https://raw.githubusercontent.com/tokuro-sedai/bootstrap/main/bootstrap.ps1 | iex
```

Expected: same eight-line output as Task 11 Step 2, ending with `ecosystem bootstrap complete.`. If the raw GitHub URL has caching delay, wait ~30 seconds after pushing and retry.

- [ ] **Step 3: No commit** (this task is integration verification only).

---

## Self-review checklist

After all tasks: skim the spec and ACs, confirm each one maps to a function or behaviour in the script.

- ac-git-on-path → Ensure-Git
- ac-git-identity → Ensure-GitConfig
- ac-claude-on-path → Ensure-Claude (+ Add-DirToUserPath)
- ac-claude-authed → Ensure-ClaudeAuth (+ Get-ClaudeAuthedEmail)
- ac-gh-authed-and-credhelper → Ensure-GhAuth (Test-GhAuthOk + Test-GhCredHelperOk + setup-git)
- ac-extremis-installed / ac-superpowers-installed → Ensure-Plugin (called twice)
- ac-arcturus-cloned → Ensure-Arcturus
- ac-rerun-is-noop → idempotent probes throughout; verified by Task 11 Step 2 second run
- ac-setup-git-idempotent → Ensure-GhAuth runs setup-git unconditionally (post-auth)
- ac-failing-step-aborts → `$ErrorActionPreference='Stop'` + explicit `throw` in each fail path
- ac-arcturus-path-collision → Ensure-Arcturus's "refusing to touch" throw
- ac-no-winget-aborts-cleanly → Ensure-Git's pre-install winget check
- ac-claude-wrong-account → Ensure-ClaudeAuth's logout-then-login on mismatch
- ac-git-identity-overwrite → Ensure-GitConfig overwrites unconditionally when probe fails
- ac-status-line-per-step → Write-StepHeader + Write-StepStatus shape
- ac-no-admin-required → no `#Requires -RunAsAdministrator`; all installs are user-scope
- ac-fetchable-via-irm → confirmed by Task 12 Step 2

All 18 ACs covered.

## Execution

Plan complete and saved to `docs/superpowers/plans/2026-04-25-ecosystem-bootstrap-implementation.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task with two-stage review between tasks.
2. **Inline Execution** — work through tasks in this session with checkpoints.

Which approach?
