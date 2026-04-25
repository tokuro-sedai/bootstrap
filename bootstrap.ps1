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
