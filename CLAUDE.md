# bootstrap

Effortless Windows 11 bootstrap for the Claude + arcturus ecosystem.
One `bootstrap.ps1` delivered via `irm | iex`. Eight idempotent steps.
See `README.md` for the user-facing description.

@docs/testing/README.md

## Build and run

No build step. Single PowerShell script. To verify locally:

```powershell
. .\bootstrap.ps1   # dot-source to import functions for testing in isolation
```

To run end-to-end on a test VM, paste the one-liner from `README.md`.

## Conventions

- PowerShell 5.1 compatible (ships with Windows 11).
- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = "Stop"`.
- Function-per-step with `Ensure-*` naming.
- Fail-fast: any error throws; subsequent steps do not run.
