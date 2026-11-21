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

Fifteen idempotent steps, each one probe → act → post-check. Nothing needs
admin, and nothing raises a UAC prompt.

Needs no account:

1. **Execution policy:** sets `RemoteSigned` for the current user, so new
   windows can load the PowerShell profile. Fresh Windows defaults to
   `Restricted`.
2. **Git:** PortableGit into `%LOCALAPPDATA%\Programs\Git`, `cmd\` on the
   user PATH.
3. **git config:** identity `Tokuro` / `jonathan.wheeler@witechnologies.org`;
   `credential.helper` = Git Credential Manager (replaces PortableGit's
   helper-picker dialog).
4. **Python 3.13** (per-user winget install; the Microsoft Store stub doesn't
   count).
5. **Claude Code:** `%USERPROFILE%\.local\bin` on the user PATH.
6. **gh:** release zip into `%LOCALAPPDATA%\Programs\gh`.
7. **Repo shortcuts:** a managed block in both PowerShell profiles. Every
   directory under `C:\source\repos\tokuro-sedai` becomes a command that
   cds there and starts `claude`. Checked by opening a new window.

Sign-ins (a browser opens; if it doesn't, Ctrl+click the link shown):

8. **Claude auth** as `jonathan.wheeler@witechnologies.org`.
9. **gh auth** as `tokuro-sedai`, with gh as git's github.com credential
   helper.

Needs those sign-ins:

10. **Repos:** clones (or fast-forwards) `arcturus` and `simulacrum` into
    `C:\source\repos\tokuro-sedai`.
11. – 13. **Plugins:** `extremis`, `superpowers` (from
    `tokuro-sedai/superpowers-fork`), `simulacrum`.
14. **Claude settings:** registers the three marketplaces with
    auto-update.
15. **`arcturus` shortcut:** a new window defines `arcturus` pointing at
    the checkout.

When it finishes: open a **new** PowerShell window and type `arcturus`.

Re-running is safe: finished steps report `already satisfied`, and repos
fast-forward. If a step fails, the script says which one. Fix the cause and
re-run the one-liner.

## Assumes

- Windows 11, regular (non-admin) user.
- A browser for the Claude and GitHub sign-ins.

## Does NOT do

- Age/sops key provisioning.
- SSH key generation or deployment.
- Per-machine role setup (SSH server, Docker host).
- Dotfiles, MCP servers beyond the three plugins.
- macOS or Linux.

## Behaviour on a non-fresh machine

- If Claude is already authed as a different account, step 8 logs out
  and prompts a re-login as `jonathan.wheeler@witechnologies.org`.
- If the global git identity is set to other values, step 3 overwrites
  to `Tokuro` / `jonathan.wheeler@witechnologies.org`.
- If `C:\source\repos\tokuro-sedai\arcturus` exists but is some other
  repo, step 10 aborts with "refusing to touch" and does not modify the
  directory.

## Testing

`python tests/vm/vmctl.py e2e` runs the script on a fresh Windows 11 VM up
to the first sign-in, unattended, and asserts every step before it. See
[`tests/vm/README.md`](tests/vm/README.md) for the harness and the
lessons behind it. Test cards live under `tests/qa/`.

## Design

`docs/superpowers/specs/` holds the original (eight-step) design spec and
its acceptance criteria. The amendments section at its end records how the
steps have changed since.
