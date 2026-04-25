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