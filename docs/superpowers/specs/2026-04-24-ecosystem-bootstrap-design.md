# Ecosystem Bootstrap Design

## Overview

A single PowerShell script, `bootstrap.ps1`, hosted in a new public GitHub
repo `tokuro-sedai/bootstrap`. One paste-able one-liner in PowerShell takes
a fresh Windows 11 machine from bare metal to a state where git has a
global identity, Claude Code is installed and authed, `gh` is authed with
the right account and acts as git's credential helper, the two ecosystem
plugins (`extremis`, `superpowers`) are installed, and `arcturus` is
cloned and ready.

The same command re-run on an already-provisioned machine is an idempotent
no-op for every step except `arcturus`, which runs `git pull`.

## Scope

### In scope — the eight steps

1. Ensure `git` is installed and on PATH.
2. Ensure git global identity is set to `Tokuro` /
   `jonathan.wheeler@witechnologies.org`.
3. Ensure `claude` is installed and on PATH (including persisting
   `%USERPROFILE%\.local\bin` to user PATH, which Claude's installer does
   not do automatically).
4. Ensure Claude Code is authed as `jonathan.wheeler@lifemaideasier.com`.
   If authed but to a different account: log out and re-auth.
5. Ensure `gh` is authed to a GitHub account with `tokuro-sedai` org access
   (`jonathan.wheeler@witechnologies.org`), AND ensure `gh` is wired as
   git's credential helper for `github.com`.
6. Ensure the `extremis` plugin is installed (marketplace:
   `tokuro-sedai/extremis`, private — requires step 5).
7. Ensure the `superpowers` plugin is installed (marketplace:
   `obra/superpowers-marketplace`).
8. Ensure `arcturus` is cloned at `C:\source\repos\tokuro-sedai\arcturus`,
   or `git pull` if already present.

### Explicitly out of scope

- Age/sops key provisioning. A fresh machine cannot decrypt
  `secrets/secrets.enc.yaml`; the user handles this separately (scp from
  a trusted machine, manual paste, etc.). The existing
  `scripts/setup-mlaptop.ps1` / `scripts/setup-alnilam.ps1` flows are
  untouched.
- SSH key generation or deployment.
- Per-machine role setup (SSH server, Docker host, etc.).
- Dotfiles, MCP servers beyond the two plugins, editor configuration.
- Per-directory git identity overrides (`includeIf.gitdir:...`). Single
  global identity now; conditional rules can be added later without
  touching this design.
- macOS or Linux. Windows-only for now; structure the design so a sibling
  `bootstrap.sh` could be added later when a Linux box enters the picture.
- Active version bumps on existing installs (no `claude update`, no
  `winget upgrade`). Re-running the script does not force anything to a
  newer version except `arcturus`, which is pulled.

## Constraints

- Windows 11 target. `winget` is assumed to be present (ships with
  Windows 11); fail-fast with a clear error if it isn't.
- Runs as a regular user — no `#Requires -RunAsAdministrator`. All four
  install paths (`winget install Git.Git`, Claude's native installer,
  `winget install GitHub.cli`, `gh repo clone`) are user-scope.
- No external dependencies beyond what's in the box on Windows 11
  (PowerShell 5.1, `winget`). Git is the first thing the script installs;
  everything else may depend on it.
- PowerShell ExecutionPolicy is irrelevant: the script is delivered via
  `irm | iex`, which downloads the file as a string and runs it via
  `Invoke-Expression` in the current session. ExecutionPolicy only
  restricts loading `.ps1` files from disk. This mirrors how Claude's own
  installer is distributed.
- The script itself must not require auth to download. The hosting repo
  (`tokuro-sedai/bootstrap`) is public.

## Approach: Single idempotent PowerShell script, eight probes

One flat `bootstrap.ps1`, fail-fast, function-per-step. Each function has
the same shape:

```powershell
function Ensure-<Thing> {
    $state = Probe-<Thing>           # 'ok' | 'missing' | 'wrong'
    if ($state -eq 'ok') {
        return @{ status = 'skipped'; detail = <current-value> }
    }
    Install-Or-Fix-<Thing>
    $after = Probe-<Thing>
    if ($after -ne 'ok') {
        throw "Ensure-<Thing> post-check failed: $after"
    }
    return @{ status = 'changed'; detail = <new-value> }
}
```

The main body of the script is a linear sequence of eight calls, each
printing one status line. A final summary block reports what happened at
each step and exits 0 on success, non-zero on failure (PowerShell's
default `throw` → non-zero exit code).

Alternatives considered and rejected:

- **Phased with pauses** — install all binaries first, then batch auth
  prompts. Adds friction to a script meant to be effortless.
- **Modular (one file per step)** — over-engineered for eight steps of
  ~15 lines each.
- **Declarative (DSC / Ansible-style)** — tool overhead far exceeds the
  value for a personal bootstrap.

## Repo Layout

Public repo `github.com/tokuro-sedai/bootstrap`:

```
bootstrap/
  README.md       # the copy-paste landing page
  bootstrap.ps1   # the script
```

`README.md` leads with the one-liner in a fenced code block so the user
can click the repo, click the readme, copy the line, paste into
PowerShell:

    irm https://raw.githubusercontent.com/tokuro-sedai/bootstrap/main/bootstrap.ps1 | iex

Below that, a short description of what the script guarantees (the eight
steps), what it assumes (Windows 11, `winget` available), and what it
does NOT do (the out-of-scope list above).

## Step Details

### 1. Ensure-Git

- **Probe**: `Get-Command git -ErrorAction SilentlyContinue`. If present,
  capture `git --version`.
- **Fix**: `winget install --id Git.Git -e --source winget --silent`.
- **Post**: refresh `$env:PATH` from user + machine env to pick up the
  newly-installed binary in the current session.

### 2. Ensure-GitConfig

- **Probe**:
  - `git config --global user.name` equals `Tokuro`
  - `git config --global user.email` equals
    `jonathan.wheeler@witechnologies.org`
  - If either is unset or different, the step is not satisfied.
- **Fix**:
  - `git config --global user.name 'Tokuro'`
  - `git config --global user.email 'jonathan.wheeler@witechnologies.org'`
- **Scope**: global, single identity for every repo on the machine. If a
  secondary identity is ever needed (e.g., for non-tokuro-sedai repos),
  that will be layered on via `includeIf.gitdir:...` in a future change;
  it's deliberately out of scope here.
- **Idempotency**: writing an already-correct config value is a no-op,
  but the probe-before-fix avoids even that.

### 3. Ensure-Claude

- **Probe**: `Get-Command claude -ErrorAction SilentlyContinue`. If
  present, capture `claude --version`.
- **Fix**:
  1. `irm https://claude.ai/install.ps1 | iex` (Claude's native installer).
  2. Install target is `%USERPROFILE%\.local\bin\claude.exe`. The
     installer does NOT update PATH. Persist the bin directory to user
     PATH via
     `[Environment]::SetEnvironmentVariable("Path", $newPath, "User")`,
     guarding against double-append.
  3. Refresh `$env:PATH` so later steps in the same run can invoke `claude`.
- **Idempotency**: if `~/.local/bin` is already on user PATH, skip the
  `setx`. If already in `$env:PATH`, skip the in-process refresh.

### 4. Ensure-ClaudeAuth

- **Probe**: `claude auth status` parsed for the authed email. State is
  `ok` iff the email matches `jonathan.wheeler@lifemaideasier.com`.
- **Fix**: if authed to the wrong account, `claude auth logout` first,
  then `claude auth login` (interactive — opens a browser, user completes
  OAuth).
- **Verify-and-re-auth** is the explicit policy: the script's job is to
  set up *this* ecosystem, so an unrelated Claude login does not count as
  satisfied.
- **Post**: re-probe; fail if the authed email still isn't the expected
  one.

### 5. Ensure-GhAuth

Split probe: satisfied iff BOTH of these hold.

- **Sub-probe 5a — gh authed**: `gh auth status` shows
  authenticated + expected username on `github.com` + `tokuro-sedai` org
  visible (`gh api /user/orgs --jq '.[].login'` contains `tokuro-sedai`).
- **Sub-probe 5b — git credential helper wired**:
  `git config --get-all credential.https://github.com.helper` contains
  `gh auth git-credential` (or equivalent `gh`-based helper line).

- **Fix**:
  1. If 5a fails: `gh auth login --web --hostname github.com
     --git-protocol https` (interactive — user picks HTTPS, logs in via
     browser as `jonathan.wheeler@witechnologies.org`).
  2. Unconditionally after 5a is satisfied: `gh auth setup-git
     --hostname github.com`. This is idempotent and guarantees the
     credential helper is wired regardless of what the user chose inside
     the `gh auth login` prompt.
- **Post**: re-run both sub-probes; fail if either still fails.

**Why step 5 precedes plugin installs**: `tokuro-sedai/extremis` is a
private marketplace repo, so `claude plugin marketplace add
tokuro-sedai/extremis` depends on `git` being able to fetch from a
private GitHub repo, which depends on `gh`'s credential helper being
wired.

### 6. Ensure-Plugin: extremis

A parameterised helper:

```powershell
function Ensure-Plugin {
    param(
        [string]$PluginName,      # e.g. 'extremis'
        [string]$MarketplaceRepo, # e.g. 'tokuro-sedai/extremis'
        [string]$PluginSpec       # e.g. 'extremis@extremis'
    )
    # probe:
    #   $installed = claude plugin list --json | ConvertFrom-Json
    #   $ok = $installed | Where-Object { $_.id -like "$PluginName@*" }
    # if not $ok:
    #   claude plugin marketplace add $MarketplaceRepo
    #   claude plugin install $PluginSpec --scope user
    # re-probe
}
```

Called with:

- `PluginName = 'extremis'`
- `MarketplaceRepo = 'tokuro-sedai/extremis'`
- `PluginSpec = 'extremis@extremis'`

### 7. Ensure-Plugin: superpowers

Same helper, called with:

- `PluginName = 'superpowers'`
- `MarketplaceRepo = 'obra/superpowers-marketplace'`
- `PluginSpec = 'superpowers@superpowers-marketplace'`

**Wildcard marketplace match in probe**: the probe checks for any
installed plugin whose id starts with `superpowers@`, regardless of
marketplace. This handles the observed case where Claude Code may resolve
`superpowers` through `anthropics/claude-plugins-official` even when the
user explicitly added `obra/superpowers-marketplace`. Either resolution
satisfies the step.

### 8. Ensure-Arcturus

- **Target**: `C:\source\repos\tokuro-sedai\arcturus`.
- **Probe**: path exists AND is a git work tree AND `git remote get-url
  origin` points to `tokuro-sedai/arcturus` (HTTPS or SSH form both
  accepted).
- **Fix**:
  - If path does not exist: ensure parent directories, then
    `gh repo clone tokuro-sedai/arcturus
    C:\source\repos\tokuro-sedai\arcturus`.
  - If path exists and is a matching repo: `git -C <path> pull`.
  - If path exists but is not a matching repo: fail fast with a clear
    error ("target path exists but is not a tokuro-sedai/arcturus
    checkout — refusing to touch"). Do not delete or rename user data.

## Error Handling

- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = "Stop"`
  at script entry, matching the convention established by
  `scripts/setup-mlaptop.ps1` and `scripts/setup-alnilam.ps1`.
- Any failing step throws and aborts. The user reads the error, fixes
  the root cause, re-runs the one-liner.
- Network failures, missing `winget`, failed installer downloads, wrong
  account after re-auth, and `tokuro-sedai/arcturus` path collisions all
  surface as legible errors rather than silent continuation.

## Output Format

One line per step as it runs:

```
[1/8] git                  ... already satisfied (git 2.47.1)
[2/8] git config           ... set (Tokuro <jonathan.wheeler@witechnologies.org>)
[3/8] claude               ... installed (claude 4.7.0)
[4/8] claude auth          ... already satisfied (jonathan.wheeler@lifemaideasier.com)
[5/8] gh auth              ... authed + git credential helper configured
[6/8] plugin: extremis     ... installed (extremis@extremis 0.10.3)
[7/8] plugin: superpowers  ... already satisfied (superpowers@claude-plugins-official 5.0.7)
[8/8] arcturus             ... pulled, 3 new commits (C:\source\repos\tokuro-sedai\arcturus)

ecosystem bootstrap complete.
```

On failure, the banner is omitted and PowerShell returns non-zero.

## Testing Approach

Acceptance criteria and test cards are authored in the next phase
(`/writing-acceptance-criteria`, `/managing-test-cases`). The tests this
feature will need, at a minimum:

- **Smoke — fresh Windows VM**: one-liner from empty Windows 11 state,
  assert all eight post-conditions.
- **Re-run — provisioned machine**: run the one-liner on a fully
  provisioned machine, assert all non-arcturus steps print "already
  satisfied" and the arcturus step runs `git pull` only.
- **Wrong-account recovery**: pre-authed Claude with a different email or
  pre-authed `gh` as a different user → script clears and re-auths.
- **Wrong git-config recovery**: a pre-set global `user.name` /
  `user.email` that differs from the expected values → script overwrites
  to the expected values.
- **Network failure**: network drop during install → fail-fast with a
  legible error.
- **Path collision**: target arcturus path exists as an unrelated git
  repo → fail-fast, no destructive action.

Test cards live at `tests/qa/` in this repo, per the project convention
(`docs/testing/README.md`). Each AC in the Acceptance Criteria section
below maps to one or more test cards via the card's `covers:`
frontmatter field.

## Acceptance Criteria

Slugs are stable — test cards reference them via `covers:` frontmatter.

### Post-conditions after a successful run

- **ac-git-on-path** (step 1) — `git --version` returns a version string;
  `git` is resolvable on PATH.
- **ac-git-identity** (step 2) — `git config --global user.name` outputs
  `Tokuro`, AND `git config --global user.email` outputs
  `jonathan.wheeler@witechnologies.org`.
- **ac-claude-on-path** (step 3) — `claude --version` returns a version
  string, AND `%USERPROFILE%\.local\bin` is persisted on user PATH
  (verifiable in a fresh PowerShell session).
- **ac-claude-authed** (step 4) — `claude auth status` reports
  authenticated as `jonathan.wheeler@lifemaideasier.com`.
- **ac-gh-authed-and-credhelper** (step 5) — `gh auth status` shows
  authenticated on github.com with `tokuro-sedai` org access, AND
  `git config --get-all credential.https://github.com.helper` contains
  a `gh auth git-credential` entry.
- **ac-extremis-installed** (step 6) — `claude plugin list --json`
  contains a plugin whose id matches `extremis@*`.
- **ac-superpowers-installed** (step 7) — `claude plugin list --json`
  contains a plugin whose id matches `superpowers@*`.
- **ac-arcturus-cloned** (step 8) —
  `C:\source\repos\tokuro-sedai\arcturus` is a git work tree whose
  origin resolves to `tokuro-sedai/arcturus`.

### Idempotency and re-run behavior

- **ac-rerun-is-noop** — Run on a fully-provisioned machine: every step
  whose probe is satisfied produces an "already satisfied" status line
  and performs no side effects. The arcturus step runs `git pull`
  (which is itself a no-op when up to date).
- **ac-setup-git-idempotent** — `gh auth setup-git --hostname
  github.com` is safe to run on every invocation: re-running does not
  duplicate or corrupt the credential helper configuration.

### Error handling

- **ac-failing-step-aborts** — If any step's probe remains unsatisfied
  after its fix action, the script aborts with a non-zero exit code
  and a legible error that names the failing step. No subsequent steps
  run.
- **ac-arcturus-path-collision** — If the target arcturus path exists
  but is not a `tokuro-sedai/arcturus` checkout, the script aborts
  with a "refusing to touch" error and does not modify the existing
  directory.
- **ac-no-winget-aborts-cleanly** — If `winget` is absent, the script
  aborts at step 1 with a clear error rather than cascading failures
  through later steps.

### Wrong-account recovery

- **ac-claude-wrong-account** — If Claude is pre-authed to a different
  email, the script runs `claude auth logout` and `claude auth login`,
  re-probes, and succeeds only once the authed email matches
  `jonathan.wheeler@lifemaideasier.com`.
- **ac-git-identity-overwrite** — If global `user.name` or `user.email`
  is pre-set to a different value, the script overwrites to the
  expected values.

### Output format

- **ac-status-line-per-step** — The script produces exactly one status
  line per step in the form `[N/8] <label> ... <detail>`. On a
  successful run it ends with `ecosystem bootstrap complete.`. On
  failure, the success banner is omitted.

### Environment

- **ac-no-admin-required** — The script runs successfully as a
  non-administrator user. No `#Requires -RunAsAdministrator` directive
  is used.
- **ac-fetchable-via-irm** — The script is fetchable via unauthenticated
  HTTPS from `raw.githubusercontent.com/tokuro-sedai/bootstrap/main/bootstrap.ps1`.
  The `irm <url> | iex` invocation does not trigger PowerShell
  ExecutionPolicy.

## Day-to-Day Workflow

Fresh Windows 11 machine:

1. Open PowerShell.
2. Paste `irm https://raw.githubusercontent.com/tokuro-sedai/bootstrap/main/bootstrap.ps1 | iex`.
3. Complete the browser flows for `claude auth login` and `gh auth login`
   when prompted.
4. When the script finishes, `cd C:\source\repos\tokuro-sedai\arcturus`
   and start working.

Existing machine, to refresh arcturus and verify the ecosystem:

1. Open PowerShell.
2. Paste the same one-liner.
3. Script reports seven "already satisfied" lines and one
   "arcturus: pulled / up to date" line.

## Future Extensions (Not In Scope)

- `bootstrap.sh` sibling for macOS and Linux, sharing the same eight
  logical steps with OS-specific install mechanics.
- Optional flag to bootstrap a secondary seat (different Claude account).
- Per-directory git identity overrides via `includeIf.gitdir:...` for
  non-tokuro-sedai repos on the same machine.
- A downstream `scripts/provision.ps1` inside arcturus that picks up
  where `bootstrap.ps1` leaves off: age key import, SSH keygen, machine
  role setup.
