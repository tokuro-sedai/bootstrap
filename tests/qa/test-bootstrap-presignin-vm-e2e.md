---
name: bootstrap-presignin-vm-e2e
kind: e2e
status: active
timeout: 5400
env: clean-win11-vm
covers:
  - ac-fetchable-via-irm
  - ac-no-admin-required
  - ac-execution-policy-for-new-windows
  - ac-git-on-path
  - ac-git-identity
  - ac-python-real
  - ac-claude-on-path
  - ac-gh-on-path
  - ac-profile-block-loads
  - ac-signin-last
---

# Pre-sign-in fresh-install e2e (automated, no accounts)

Runs `bootstrap.ps1` on the fresh VM in a real user window, stopping right
before the first sign-in, and asserts every step before that point.

## Setup

None. The runner restores the `fresh` snapshot itself.

## Test Instructions

```bash
python tests/vm/vmctl.py e2e     # add --bootstrap <path> to test another copy
```

## Pass Criteria

- The output ends with `E2E-VERDICT PASS` (exit 0). That means steps 1–7
  (`execution policy`, `git`, `git config`, `python`, `claude`, `gh`,
  `repo shortcuts`) each reported `changed` or `already satisfied`, and the
  run printed `BOOTSTRAP_STOP_BEFORE_SIGNIN=1: stopped before step 8`.
- **ac-no-admin-required**: `launch --wait` printed no `UAC consent prompt`
  line.
- **ac-profile-block-loads**: covered by step 7's own post-check. A new
  Windows PowerShell, with the user's real execution policy, ran the
  managed profile block.
- **ac-signin-last**: nothing before the stop line asked for input.

Optional re-run check (`ac-rerun-is-noop` for these steps):
`python tests/vm/vmctl.py e2e --no-reset`. Every step should be
`already satisfied`.

## Teardown

None required. The next `e2e` restores `fresh`.
