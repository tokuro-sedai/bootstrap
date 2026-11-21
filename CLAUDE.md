# bootstrap

Effortless Windows 11 bootstrap for the Claude + arcturus ecosystem.
One `bootstrap.ps1` delivered via `irm | iex`. Fifteen idempotent steps; the ones that need no account run before the first sign-in.
See `README.md` for the user-facing description.

@docs/testing/README.md

## Build and run

No build step. Single PowerShell script. **Never run or dot-source it on a dev
machine:** it ends by calling `Main`, which rewrites the user's PowerShell
profile, git config, PATH and Claude auth. To verify locally:

```powershell
# Parse check (must be 0), then exercise ONE function, extracted from the AST.
$e = $null; [void][Management.Automation.Language.Parser]::ParseFile((Resolve-Path bootstrap.ps1), [ref]$null, [ref]$e); $e.Count
$ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path bootstrap.ps1), [ref]$null, [ref]$null)
$fn  = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-Interactive' }, $true)
. ([scriptblock]::Create($fn.Extent.Text))
```

Keep the file ASCII-only, with no BOM: `irm | iex` and PowerShell 5.1 mangle
anything else.

To run end-to-end on a fresh Windows 11 VM: `python tests/vm/vmctl.py e2e`
(unattended, up to the first sign-in; see `tests/vm/README.md`). Read the
PowerShell 5.1 traps listed in the `bootstrap.ps1` header before changing it.

## Conventions

- PowerShell 5.1 compatible (ships with Windows 11).
- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = "Stop"`.
- Function-per-step with `Ensure-*` naming.
- Fail-fast: any error throws; subsequent steps do not run.
- Order: steps that need no account go above the `BOOTSTRAP_STOP_BEFORE_SIGNIN`
  boundary in `Main`, so the unattended VM e2e covers them.
