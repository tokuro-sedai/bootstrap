# bootstrap

Effortless Windows 11 bootstrap for the Claude + arcturus ecosystem.
One PowerShell command takes a fresh machine from bare metal to a
working development state.

## The one-liner

Open PowerShell and paste:

```powershell
irm https://raw.githubusercontent.com/tokuro-sedai/bootstrap/main/bootstrap.ps1 | iex
```

## What it does

Eight idempotent steps:

1. Installs `git` (if missing).
2. Sets global git identity to `Tokuro` /
   `jonathan.wheeler@witechnologies.org`.
3. Installs Claude Code (if missing) and persists
   `%USERPROFILE%\.local\bin` to user PATH.
4. Authenticates Claude Code as `jonathan.wheeler@lifemaideasier.com`
   (opens a browser).
5. Authenticates `gh` as the `tokuro-sedai`-org account, and wires
   `gh` as git's credential helper for `github.com`.
6. Installs the `extremis` plugin from `tokuro-sedai/extremis`.
7. Installs the `superpowers` plugin from `obra/superpowers-marketplace`.
8. Clones `tokuro-sedai/arcturus` to
   `C:\source\repos\tokuro-sedai\arcturus` (or `git pull` if already
   present).

Re-runs on an already-provisioned machine are a no-op except for the
arcturus step, which runs `git pull`.

## Assumes

- Windows 11, regular user (no admin prompt).
- `winget` is present (ships with Windows 11).
- A browser is available for Claude and `gh` OAuth flows.

## Does NOT do

- Age/sops key provisioning.
- SSH key generation or deployment.
- Per-machine role setup (SSH server, Docker host).
- Dotfiles, MCP servers beyond the two plugins.
- macOS or Linux.

## Behaviour on a non-fresh machine

- If Claude is already authed as a different account, step 4 logs out
  and prompts a re-login as `jonathan.wheeler@lifemaideasier.com`.
- If the global git identity is set to other values, step 2 overwrites
  to `Tokuro` / `jonathan.wheeler@witechnologies.org`.
- If `C:\source\repos\tokuro-sedai\arcturus` exists but is some other
  repo, step 8 aborts with "refusing to touch" and does not modify the
  directory.

## Design

See `docs/superpowers/specs/` for the design spec and acceptance
criteria. Test cards live under `tests/qa/`.
