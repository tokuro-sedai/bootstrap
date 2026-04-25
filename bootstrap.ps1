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
