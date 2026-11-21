#Requires -Version 5.1
<#
.SYNOPSIS
    Bootstrap a fresh Windows 11 machine for the Claude + arcturus ecosystem.

.DESCRIPTION
    Idempotent steps, each probe -> act -> post-check. See README.md and the
    design spec under docs/superpowers/specs/.

.NOTES
    Delivered via `irm | iex` into Windows PowerShell 5.1. Rules this script
    lives by (each one was a real failure on a fresh install):

    * Never redirect a native command's stderr while $ErrorActionPreference
      is 'Stop': Windows PowerShell 5.1 turns the first stderr line into a
      terminating NativeCommandError. All captured native calls go through
      Invoke-Native.
    * Never `exit` and never `iex` third-party installers into this session:
      an `exit` inside them closes the user's PowerShell window. Child
      process instead.
    * No admin. Every install is per-user; nothing raises a UAC prompt.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest is 10x slower with the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# --- expected identities and target paths --------------------------------

$Script:ExpectedClaudeEmail = 'jonathan.wheeler@witechnologies.org'
$Script:ExpectedGitName     = 'Tokuro'
$Script:ExpectedGitEmail    = 'jonathan.wheeler@witechnologies.org'
$Script:ExpectedGhLogin     = 'tokuro-sedai'
$Script:RepoRoot            = 'C:\source\repos\tokuro-sedai'
$Script:ArcturusRepo        = 'tokuro-sedai/arcturus'
$Script:SimulacrumRepo      = 'tokuro-sedai/simulacrum'
$Script:ClaudeBinDir        = Join-Path $env:USERPROFILE '.local\bin'
$Script:GhInstallDir        = Join-Path $env:LOCALAPPDATA 'Programs\gh'
$Script:GitInstallDir       = Join-Path $env:LOCALAPPDATA 'Programs\Git'

$Script:Plugins = @(
    @{ Name = 'extremis';    Marketplace = 'extremis';        Source = 'https://github.com/tokuro-sedai/extremis.git'; Kind = 'git'    },
    @{ Name = 'superpowers'; Marketplace = 'superpowers-dev'; Source = 'tokuro-sedai/superpowers-fork';                Kind = 'github' },
    @{ Name = 'simulacrum';  Marketplace = 'simulacrum';      Source = (Join-Path $Script:RepoRoot 'simulacrum');      Kind = 'directory' }
)

$Script:StepCount = 13
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
    $word  = @{ skipped = 'already satisfied'; changed = 'changed'; failed = 'FAILED' }[$Status]
    $color = @{ skipped = 'DarkGray';          changed = 'Green';   failed = 'Red'    }[$Status]
    Write-Host " $word ($Detail)" -ForegroundColor $color
}

function Write-Prompt {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ""
    Write-Host "  $Message" -ForegroundColor Yellow
}

# --- native-command + environment helpers --------------------------------

function Invoke-Native {
    # Run a native command, capturing stdout+stderr as strings, WITHOUT letting
    # Windows PowerShell 5.1 turn stderr into a terminating error.
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
    [pscustomobject]@{ ExitCode = $code; Output = @($out); Text = (@($out) -join "`n") }
}

function Invoke-Interactive {
    # Run a native command attached to the REAL console (browser/device-code
    # flows), returning its exit code. `& cmd` inside a function sends the
    # command's stdout into the function's output pipeline: the user never sees
    # the URL/code and the tool sees a non-TTY stdout (no browser). Start-Process
    # -NoNewWindow hands the child this window's console handles directly.
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    $exe = (Get-Command $FilePath -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $quoted = @($ArgumentList | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } })
    $spArgs = @{ FilePath = $exe; NoNewWindow = $true; Wait = $true; PassThru = $true }
    if ($quoted.Count -gt 0) { $spArgs.ArgumentList = $quoted }
    $p = Start-Process @spArgs
    return $p.ExitCode
}

function Update-EnvPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:PATH = ($machine, $user | Where-Object { $_ }) -join ';'
}

function Add-DirToUserPath {
    param([Parameter(Mandatory)][string]$Dir)
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $segments = @(if ($userPath) { $userPath -split ';' | Where-Object { $_ } })
    if ($segments -notcontains $Dir) {
        [Environment]::SetEnvironmentVariable('Path', (@($segments) + $Dir) -join ';', 'User')
    }
    Update-EnvPath
}

function Test-Cmd { param([string]$Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Get-WingetPath {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # On a brand-new profile App Installer is staged but not yet registered.
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop
    } catch { }
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    for ($i = 0; $i -lt 12; $i++) {
        if (Test-Path $alias) { return $alias }
        Start-Sleep -Seconds 5
    }
    return $null
}

function Invoke-WingetUserInstall {
    # Per-user winget install; never elevates.
    param([Parameter(Mandatory)][string]$Id)
    $winget = Get-WingetPath
    if (-not $winget) {
        throw "winget is not available -- cannot install $Id. Open the Microsoft Store, update 'App Installer', and re-run."
    }
    $r = Invoke-Native $winget @('install', '--id', $Id, '-e', '--source', 'winget', '--scope', 'user',
                                 '--silent', '--disable-interactivity',
                                 '--accept-source-agreements', '--accept-package-agreements')
    # -1978335189 (0x8A15002B) = already installed / no applicable upgrade
    if ($r.ExitCode -ne 0 -and $r.ExitCode -ne -1978335189) {
        throw "winget install $Id (user scope) failed with exit code $($r.ExitCode):`n$($r.Text)"
    }
    Update-EnvPath
}

# --- step: PowerShell execution policy -----------------------------------

function Get-PersistentExecutionPolicy {
    # The policy a NEW PowerShell window gets: ignore the Process scope (an
    # `-ExecutionPolicy Bypass` launch would otherwise mask a Restricted user).
    foreach ($scope in 'MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine') {
        $p = Get-ExecutionPolicy -Scope $scope
        if ("$p" -ne 'Undefined') { return "$p" }
    }
    return 'Restricted'   # Windows client default when nothing is set
}

function Ensure-ExecutionPolicy {
    Write-StepHeader -Label 'execution policy'
    # Fresh Windows 11 client defaults to Restricted, which blocks profile.ps1
    # (and therefore the repo shortcuts). CurrentUser scope needs no admin.
    $before = Get-PersistentExecutionPolicy
    if ($before -in 'RemoteSigned', 'Unrestricted', 'Bypass') {
        Write-StepStatus -Status skipped -Detail "new windows get $before"
        return
    }
    try {
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
    } catch [System.Security.SecurityException] {
        # "updated successfully, but overridden by a more specific scope": the
        # CurrentUser value WAS written; this window just has a Process-scope
        # override (e.g. launched with -ExecutionPolicy Bypass). The post-check
        # below verifies what a new window gets.
    }
    $after = Get-PersistentExecutionPolicy
    if ($after -notin 'RemoteSigned', 'Unrestricted', 'Bypass') {
        throw "Ensure-ExecutionPolicy post-check failed: new windows still get $after (a Group Policy may be overriding CurrentUser)."
    }
    Write-StepStatus -Status changed -Detail "$before -> RemoteSigned (CurrentUser)"
}

# --- step: git -----------------------------------------------------------

function Install-GitPortable {
    # winget's Git.Git "user scope" entry runs the machine installer, which
    # elevates itself (UAC). PortableGit is the official self-extracting build:
    # full Git + Git Bash (Claude Code needs bash), unpacked per-user, no admin.
    $rel = Invoke-RestMethod -UseBasicParsing 'https://api.github.com/repos/git-for-windows/git/releases/latest'
    $asset = $rel.assets | Where-Object { $_.name -match '^PortableGit-[\d.]+-64-bit\.7z\.exe$' } | Select-Object -First 1
    if (-not $asset) { throw "Could not find a PortableGit 64-bit asset in git-for-windows release $($rel.tag_name)." }
    $tmp = Join-Path $env:TEMP "portablegit-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $sfx = Join-Path $tmp $asset.name
        Invoke-WebRequest -UseBasicParsing $asset.browser_download_url -OutFile $sfx
        if (Test-Path $Script:GitInstallDir) { Remove-Item -Recurse -Force $Script:GitInstallDir }
        # 7-Zip SFX: -o<dir> target, -y no prompts. Wait for it to finish.
        $p = Start-Process -FilePath $sfx -ArgumentList @("-o`"$($Script:GitInstallDir)`"", '-y') -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -ne 0) { throw "PortableGit extraction exited with $($p.ExitCode)." }
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
    Add-DirToUserPath -Dir (Join-Path $Script:GitInstallDir 'cmd')
    # Tell Claude Code where Git Bash is (it can't infer it for a non-standard install dir).
    $bash = Join-Path $Script:GitInstallDir 'bin\bash.exe'
    [Environment]::SetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', $bash, 'User')
    $env:CLAUDE_CODE_GIT_BASH_PATH = $bash
    return $rel.tag_name
}

function Ensure-Git {
    Write-StepHeader -Label 'git'
    if (-not (Test-Cmd git) -and (Test-Path (Join-Path $Script:GitInstallDir 'cmd\git.exe'))) {
        Add-DirToUserPath -Dir (Join-Path $Script:GitInstallDir 'cmd')
    }
    if (Test-Cmd git) {
        Write-StepStatus -Status skipped -Detail ((Invoke-Native git @('--version')).Text)
        return
    }
    $tag = Install-GitPortable
    if (-not (Test-Cmd git)) { throw "Ensure-Git post-check failed: git still not on PATH after install." }
    Write-StepStatus -Status changed -Detail ("installed PortableGit $tag -> $Script:GitInstallDir (" + (Invoke-Native git @('--version')).Text + ")")
}

# --- step: git config ----------------------------------------------------

function Ensure-GitConfig {
    Write-StepHeader -Label 'git config'
    $name  = (Invoke-Native git @('config', '--global', 'user.name')).Text.Trim()
    $email = (Invoke-Native git @('config', '--global', 'user.email')).Text.Trim()
    if ($name -eq $Script:ExpectedGitName -and $email -eq $Script:ExpectedGitEmail) {
        Write-StepStatus -Status skipped -Detail "$name <$email>"
        return
    }
    $null = Invoke-Native git @('config', '--global', 'user.name',  $Script:ExpectedGitName)
    $null = Invoke-Native git @('config', '--global', 'user.email', $Script:ExpectedGitEmail)
    $name  = (Invoke-Native git @('config', '--global', 'user.name')).Text.Trim()
    $email = (Invoke-Native git @('config', '--global', 'user.email')).Text.Trim()
    if ($name -ne $Script:ExpectedGitName -or $email -ne $Script:ExpectedGitEmail) {
        throw "Ensure-GitConfig post-check failed: name='$name' email='$email'"
    }
    Write-StepStatus -Status changed -Detail "set ($name <$email>)"
}

# --- step: python ----------------------------------------------------------

function Test-RealPython {
    # The WindowsApps 'python.exe' on a fresh install is a Store redirect stub.
    if (-not (Test-Cmd python)) { return $null }
    $r = Invoke-Native python @('-c', 'import sys; print(sys.version.split()[0])')
    if ($r.ExitCode -eq 0 -and $r.Text -match '^\d+\.\d+') { return $r.Text.Trim() }
    return $null
}

function Ensure-Python {
    Write-StepHeader -Label 'python'
    $v = Test-RealPython
    if ($v) { Write-StepStatus -Status skipped -Detail "python $v"; return }
    Invoke-WingetUserInstall -Id 'Python.Python.3.13'
    $pyDir = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313'
    if (Test-Path (Join-Path $pyDir 'python.exe')) {
        Add-DirToUserPath -Dir $pyDir
        Add-DirToUserPath -Dir (Join-Path $pyDir 'Scripts')
        # The WindowsApps stub sits earlier on PATH; put the real one first here.
        $env:PATH = "$pyDir;$(Join-Path $pyDir 'Scripts');$env:PATH"
    }
    $v = Test-RealPython
    if (-not $v) { throw "Ensure-Python post-check failed: 'python' is missing or is the Microsoft Store stub." }
    Write-StepStatus -Status changed -Detail "installed python $v"
}

# --- step: claude ----------------------------------------------------------

function Get-ClaudeVersion {
    $r = Invoke-Native claude @('--version')
    if ($r.Text -match '(\d+\.\d+\.\d+\S*)') { return $Matches[1] }
    return $r.Text.Trim()
}

function Ensure-Claude {
    Write-StepHeader -Label 'claude'
    if (-not (Test-Cmd claude) -and (Test-Path (Join-Path $Script:ClaudeBinDir 'claude.exe'))) {
        Add-DirToUserPath -Dir $Script:ClaudeBinDir
    }
    if (Test-Cmd claude) {
        Write-StepStatus -Status skipped -Detail "claude $(Get-ClaudeVersion)"
        return
    }
    # Child process: the installer calls `exit` on failure, which would close
    # this window if it were iex'd here.
    $ps = Join-Path $PSHOME 'powershell.exe'
    $r = Invoke-Native $ps @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
                             "`$ProgressPreference='SilentlyContinue'; irm https://claude.ai/install.ps1 | iex")
    if ($r.ExitCode -ne 0) { throw "Claude installer failed with exit code $($r.ExitCode):`n$($r.Text)" }
    Add-DirToUserPath -Dir $Script:ClaudeBinDir
    if (-not (Test-Cmd claude)) {
        throw "Ensure-Claude post-check failed: claude not on PATH after install (looked in $Script:ClaudeBinDir)."
    }
    Write-StepStatus -Status changed -Detail "installed claude $(Get-ClaudeVersion), $Script:ClaudeBinDir on user PATH"
}

# --- step: claude auth -----------------------------------------------------

function Get-ClaudeAuthedEmail {
    $r = Invoke-Native claude @('auth', 'status', '--json')
    try {
        $j = $r.Text | ConvertFrom-Json
        if ($j.loggedIn -and $j.PSObject.Properties['email']) { return $j.email }
        return $null
    } catch { }
    if ($r.Text -match '([\w._%+-]+@[\w.-]+\.\w+)') { return $Matches[1] }
    return $null
}

function Ensure-ClaudeAuth {
    Write-StepHeader -Label 'claude auth'
    $email = Get-ClaudeAuthedEmail
    if ($email -eq $Script:ExpectedClaudeEmail) {
        Write-StepStatus -Status skipped -Detail $email
        return
    }
    if ($email) {
        Write-Prompt "Claude is authed as $email; expected $Script:ExpectedClaudeEmail. Logging out..."
        $null = Invoke-Native claude @('auth', 'logout')
    }
    Write-Prompt "Signing in to Claude. A browser will open -- sign in as $Script:ExpectedClaudeEmail."
    $code = Invoke-Interactive claude @('auth', 'login', '--claudeai', '--email', $Script:ExpectedClaudeEmail)
    $after = Get-ClaudeAuthedEmail
    if ($after -ne $Script:ExpectedClaudeEmail) {
        throw "Ensure-ClaudeAuth post-check failed: authed as '$after' (login exit $code), expected '$Script:ExpectedClaudeEmail'."
    }
    Write-StepStatus -Status changed -Detail "authed as $after"
}

# --- step: gh + auth + git credential helper -------------------------------

function Install-GhPortable {
    # The gh MSI is machine-scope (UAC). The release zip is per-user and needs no admin.
    $rel = Invoke-RestMethod -UseBasicParsing 'https://api.github.com/repos/cli/cli/releases/latest'
    $asset = $rel.assets | Where-Object { $_.name -match '_windows_amd64\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw "Could not find a windows_amd64 zip in gh release $($rel.tag_name)." }
    $tmp = Join-Path $env:TEMP "gh-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp $asset.name
        Invoke-WebRequest -UseBasicParsing $asset.browser_download_url -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath (Join-Path $tmp 'x') -Force
        if (Test-Path $Script:GhInstallDir) { Remove-Item -Recurse -Force $Script:GhInstallDir }
        New-Item -ItemType Directory -Path $Script:GhInstallDir -Force | Out-Null
        Copy-Item -Recurse -Path (Join-Path $tmp 'x\*') -Destination $Script:GhInstallDir -Force
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
    Add-DirToUserPath -Dir (Join-Path $Script:GhInstallDir 'bin')
    return $rel.tag_name
}

function Test-GhAuthOk {
    $r = Invoke-Native gh @('api', 'user', '--jq', '.login')
    return ($r.ExitCode -eq 0 -and $r.Text.Trim() -eq $Script:ExpectedGhLogin)
}

function Test-GhCredHelperOk {
    $r = Invoke-Native git @('config', '--global', '--get-all', 'credential.https://github.com.helper')
    return ($r.Text -match 'gh(\.exe)?["'']?\s+auth\s+git-credential')
}

function Ensure-GhAuth {
    Write-StepHeader -Label 'gh auth'
    $installed = ''
    if (-not (Test-Cmd gh)) {
        $tag = Install-GhPortable
        if (-not (Test-Cmd gh)) { throw "Ensure-GhAuth post-check failed: gh not on PATH after install." }
        $installed = "installed gh $tag; "
    }
    $authOk   = Test-GhAuthOk
    $helperOk = Test-GhCredHelperOk
    if ($authOk -and $helperOk) {
        Write-StepStatus -Status skipped -Detail 'authed + credential helper wired'
        return
    }
    if (-not $authOk) {
        Write-Prompt "Signing in to GitHub. Copy the one-time code, press Enter to open the browser, and approve as '$Script:ExpectedGhLogin'."
        $code = Invoke-Interactive gh @('auth', 'login', '--web', '--hostname', 'github.com', '--git-protocol', 'https', '--skip-ssh-key')
        if ($code -ne 0) { throw "gh auth login exited with $code" }
    }
    $r = Invoke-Native gh @('auth', 'setup-git', '--hostname', 'github.com')
    if ($r.ExitCode -ne 0) { throw "gh auth setup-git failed ($($r.ExitCode)):`n$($r.Text)" }
    if (-not (Test-GhAuthOk))       { throw "Ensure-GhAuth post-check failed: gh is not authenticated as '$Script:ExpectedGhLogin'." }
    if (-not (Test-GhCredHelperOk)) { throw "Ensure-GhAuth post-check failed: git's github.com credential helper is not gh." }
    Write-StepStatus -Status changed -Detail "${installed}authed + credential helper wired"
}

# --- step: repos (arcturus + simulacrum) ----------------------------------

function Test-OriginMatches {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Repo)
    if (-not (Test-Path (Join-Path $Path '.git'))) { return $false }
    $r = Invoke-Native git @('-C', $Path, 'remote', 'get-url', 'origin')
    return ($r.ExitCode -eq 0 -and $r.Text.Trim() -match "$([regex]::Escape($Repo))(\.git)?$")
}

function Sync-Repo {
    # Clone-or-fast-forward. Returns a short status string.
    param([Parameter(Mandatory)][string]$Repo)
    $short  = ($Repo -split '/')[-1]
    $target = Join-Path $Script:RepoRoot $short
    if (Test-Path $target) {
        if (-not (Test-OriginMatches -Path $target -Repo $Repo)) {
            throw "'$target' exists but is not a $Repo checkout -- refusing to touch."
        }
        $before = (Invoke-Native git @('-C', $target, 'rev-parse', 'HEAD')).Text.Trim()
        $r = Invoke-Native git @('-C', $target, 'pull', '--ff-only')
        if ($r.ExitCode -ne 0) {
            # Local work (dirty tree / diverged / non-default branch) is not this script's business.
            return "${short}: present, pull skipped (not fast-forwardable)"
        }
        $after = (Invoke-Native git @('-C', $target, 'rev-parse', 'HEAD')).Text.Trim()
        if ($before -eq $after) { return "${short}: up to date" }
        return "${short}: pulled"
    }
    New-Item -ItemType Directory -Path $Script:RepoRoot -Force | Out-Null
    $r = Invoke-Native git @('clone', "https://github.com/$Repo.git", $target)
    if ($r.ExitCode -ne 0) { throw "git clone $Repo failed ($($r.ExitCode)):`n$($r.Text)" }
    if (-not (Test-OriginMatches -Path $target -Repo $Repo)) { throw "post-check failed: $target is not a $Repo checkout." }
    return "${short}: cloned"
}

function Ensure-Repos {
    Write-StepHeader -Label 'repos'
    $results = @((Sync-Repo -Repo $Script:ArcturusRepo), (Sync-Repo -Repo $Script:SimulacrumRepo))
    $status = if ($results | Where-Object { $_ -match 'cloned|pulled' }) { 'changed' } else { 'skipped' }
    Write-StepStatus -Status $status -Detail ("$Script:RepoRoot -- " + ($results -join '; '))
}

# --- step: plugins ---------------------------------------------------------

function Get-InstalledPluginIds {
    $r = Invoke-Native claude @('plugin', 'list', '--json')
    try { return @(($r.Text | ConvertFrom-Json) | ForEach-Object { $_.id }) } catch { return @() }
}

function Get-MarketplaceNames {
    $r = Invoke-Native claude @('plugin', 'marketplace', 'list', '--json')
    try { return @(($r.Text | ConvertFrom-Json) | ForEach-Object { $_.name }) } catch { }
    return @($r.Output | ForEach-Object { if ($_ -match '^\s*\S\s+([\w.-]+)\s*$') { $Matches[1] } })
}

function Ensure-Plugin {
    param([Parameter(Mandatory)][hashtable]$Plugin)
    Write-StepHeader -Label "plugin: $($Plugin.Name)"
    $id = "$($Plugin.Name)@$($Plugin.Marketplace)"
    if ((Get-InstalledPluginIds) -contains $id) {
        Write-StepStatus -Status skipped -Detail $id
        return
    }
    if ((Get-MarketplaceNames) -notcontains $Plugin.Marketplace) {
        $r = Invoke-Native claude @('plugin', 'marketplace', 'add', $Plugin.Source)
        if ($r.ExitCode -ne 0 -and (Get-MarketplaceNames) -notcontains $Plugin.Marketplace) {
            throw "claude plugin marketplace add $($Plugin.Source) failed ($($r.ExitCode)):`n$($r.Text)"
        }
    }
    $r = Invoke-Native claude @('plugin', 'install', $id, '--scope', 'user')
    if ((Get-InstalledPluginIds) -notcontains $id) {
        throw "Ensure-Plugin post-check failed: $id not installed (exit $($r.ExitCode)):`n$($r.Text)"
    }
    Write-StepStatus -Status changed -Detail "installed $id"
}

# --- step: claude settings (marketplace auto-update) -----------------------

function Ensure-ClaudeSettings {
    Write-StepHeader -Label 'claude settings'
    $path = Join-Path $env:USERPROFILE '.claude\settings.json'
    $json = $null
    if (Test-Path $path) { $json = Get-Content -Raw -Path $path | ConvertFrom-Json }
    if (-not $json) { $json = [pscustomobject]@{} }
    $changed = @()

    if (-not $json.PSObject.Properties['extraKnownMarketplaces']) {
        $json | Add-Member -NotePropertyName extraKnownMarketplaces -NotePropertyValue ([pscustomobject]@{})
    }
    foreach ($p in $Script:Plugins) {
        $src = switch ($p.Kind) {
            'git'       { [pscustomobject][ordered]@{ source = 'git';       url  = $p.Source } }
            'github'    { [pscustomobject][ordered]@{ source = 'github';    repo = $p.Source } }
            'directory' { [pscustomobject][ordered]@{ source = 'directory'; path = $p.Source } }
        }
        $want = [pscustomobject][ordered]@{ source = $src; autoUpdate = ($p.Kind -ne 'directory') }
        $have = $json.extraKnownMarketplaces.PSObject.Properties[$p.Marketplace]
        if (-not $have -or (($have.Value | ConvertTo-Json -Depth 5 -Compress) -ne ($want | ConvertTo-Json -Depth 5 -Compress))) {
            $json.extraKnownMarketplaces | Add-Member -Force -NotePropertyName $p.Marketplace -NotePropertyValue $want
            $changed += $p.Marketplace
        }
    }
    if (-not $changed) {
        Write-StepStatus -Status skipped -Detail 'marketplaces registered with auto-update'
        return
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
    # UTF-8 without BOM (Windows PowerShell's -Encoding utf8 writes a BOM).
    [IO.File]::WriteAllText($path, ($json | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
    $null = Get-Content -Raw $path | ConvertFrom-Json   # post-check: still valid JSON
    Write-StepStatus -Status changed -Detail ("registered " + ($changed -join ', '))
}

# --- step: repo shortcuts in the PowerShell profile ------------------------

$Script:ShortcutBegin = '# === BEGIN tokuro-sedai repo shortcuts ==='
$Script:ShortcutEnd   = '# === END tokuro-sedai repo shortcuts ==='

function Get-ShortcutBlock {
    $root = $Script:RepoRoot -replace "'", "''"
    $lines = @(
        $Script:ShortcutBegin,
        '# Managed by tokuro-sedai/bootstrap. For each directory under $repoRoot, defines',
        '# a function with that name that cds into the repo and launches `claude`.',
        '# Args after the repo name are forwarded (e.g. `arcturus --resume`).',
        "`$repoRoot = '$root'",
        'if (Test-Path -LiteralPath $repoRoot) {',
        '    Get-ChildItem -LiteralPath $repoRoot -Directory | ForEach-Object {',
        '        $body = "Set-Location -LiteralPath ''$($_.FullName -replace "''", "''''")''; claude @args"',
        '        Set-Item -Path "function:global:$($_.Name)" -Value ([scriptblock]::Create($body)) -Force',
        '    }',
        '}',
        $Script:ShortcutEnd
    )
    return ($lines -join "`r`n")
}

function Ensure-RepoShortcuts {
    Write-StepHeader -Label 'repo shortcuts'
    $docs = [Environment]::GetFolderPath('MyDocuments')   # follows OneDrive redirection
    $profiles = @(
        (Join-Path $docs 'WindowsPowerShell\profile.ps1'),   # Windows PowerShell 5.1
        (Join-Path $docs 'PowerShell\profile.ps1')           # PowerShell 7+
    )
    $block = Get-ShortcutBlock
    $pattern = '(?s)' + [regex]::Escape($Script:ShortcutBegin) + '.*?' + [regex]::Escape($Script:ShortcutEnd)
    $touched = @()
    foreach ($p in $profiles) {
        $existing = if (Test-Path $p) { [IO.File]::ReadAllText($p) } else { '' }
        if ($existing -match $pattern) {
            $new = [regex]::Replace($existing, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($m) $block })
        } elseif ($existing.Trim()) {
            $new = $existing.TrimEnd() + "`r`n`r`n" + $block + "`r`n"
        } else {
            $new = $block + "`r`n"
        }
        if ($new -ne $existing) {
            New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null
            [IO.File]::WriteAllText($p, $new, (New-Object Text.UTF8Encoding($true)))
            $touched += $p
        }
    }
    # Post-check: a NEW Windows PowerShell loads the profile and defines `arcturus`.
    # Drop any inherited process-scope policy so the child sees what a fresh window sees.
    $savedPref = $env:PSExecutionPolicyPreference
    Remove-Item Env:\PSExecutionPolicyPreference -ErrorAction SilentlyContinue
    try {
        $check = Invoke-Native (Join-Path $PSHOME 'powershell.exe') @('-NoLogo', '-NonInteractive', '-Command',
            "if (Get-Command arcturus -CommandType Function -ErrorAction SilentlyContinue) { 'SHORTCUT-OK' } else { 'SHORTCUT-MISSING' }")
    } finally {
        if ($null -ne $savedPref) { $env:PSExecutionPolicyPreference = $savedPref }
    }
    if ($check.Text -notmatch 'SHORTCUT-OK') {
        throw "Ensure-RepoShortcuts post-check failed: a new PowerShell does not define 'arcturus':`n$($check.Text)"
    }
    if ($touched) { Write-StepStatus -Status changed -Detail ("wrote " + ($touched -join ', ')) }
    else          { Write-StepStatus -Status skipped -Detail 'profile block current' }
}

# --- main ------------------------------------------------------------------

function Main {
    $Script:StepIndex = 0
    try {
        Ensure-ExecutionPolicy
        Ensure-Git
        Ensure-GitConfig
        Ensure-Python
        Ensure-Claude
        Ensure-ClaudeAuth
        Ensure-GhAuth
        Ensure-Repos
        foreach ($p in $Script:Plugins) { Ensure-Plugin -Plugin $p }
        Ensure-ClaudeSettings
        Ensure-RepoShortcuts
    } catch {
        Write-StepStatus -Status failed -Detail $_.Exception.Message
        Write-Host ""
        Write-Host "bootstrap stopped at step $Script:StepIndex of $Script:StepCount. Fix the cause above and re-run the one-liner; finished steps are skipped." -ForegroundColor Red
        return
    }
    Write-Host ""
    Write-Host "ecosystem bootstrap complete." -ForegroundColor Green
    Write-Host "Open a NEW PowerShell window and type: arcturus" -ForegroundColor Green
}

Main
