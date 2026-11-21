# Acceptance: in a NEW PowerShell window (real user policy, profile loaded),
# `arcturus` is defined, cds into the arcturus checkout, and launches an
# authenticated Claude session that has the extremis + superpowers plugins.
# Run via: vmctl.py launch --name accept --script tests/vm/accept-arcturus.ps1 --wait
# Every result line starts with ACCEPT- so the harness can grep a verdict.

$ErrorActionPreference = 'Continue'
$expected = 'C:\source\repos\tokuro-sedai\arcturus'
$pass = $true

$policy = Get-ExecutionPolicy
Write-Host "ACCEPT-POLICY $policy"

$fn = Get-Command arcturus -CommandType Function -ErrorAction SilentlyContinue
if (-not $fn) {
    Write-Host "ACCEPT-FAIL shortcut: 'arcturus' is not defined in a new window (profile not loaded? policy=$policy)"
    return
}
Write-Host "ACCEPT-OK shortcut defined"

$prompt = @'
Answer in exactly three lines, nothing else:
CWD=<the absolute path of your current working directory>
EXTREMIS=<YES if a skill whose name starts with "extremis:" is available to you, else NO>
SUPERPOWERS=<YES if a skill whose name starts with "superpowers:" is available to you, else NO>
'@
$reply = (arcturus -p $prompt 2>&1 | Out-String)
$here = (Get-Location).Path
Write-Host "ACCEPT-REPLY $($reply.Trim() -replace "`r?`n", ' | ')"

if ($here -ne $expected) { $pass = $false; Write-Host "ACCEPT-FAIL cd: window is in '$here', expected '$expected'" }
else                     { Write-Host "ACCEPT-OK cd into $here" }

if ($reply -match 'CWD=\s*(.+)' -and $Matches[1].Trim().TrimEnd('\') -ieq $expected) { Write-Host "ACCEPT-OK claude runs in arcturus" }
else { $pass = $false; Write-Host "ACCEPT-FAIL claude cwd/launch (reply above)" }

foreach ($p in 'EXTREMIS', 'SUPERPOWERS') {
    if ($reply -match "$p=\s*YES") { Write-Host "ACCEPT-OK $($p.ToLower()) plugin loaded" }
    else { $pass = $false; Write-Host "ACCEPT-FAIL $($p.ToLower()) plugin not visible to the session" }
}

Write-Host $(if ($pass) { 'ACCEPT-VERDICT PASS' } else { 'ACCEPT-VERDICT FAIL' })
