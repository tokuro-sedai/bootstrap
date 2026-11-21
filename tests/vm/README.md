# VM end-to-end harness

Fresh-install Windows 11 tests for `bootstrap.ps1`, run in a local VirtualBox
VM, driven entirely from the host through `VBoxManage`. Nothing types into or
clicks on the host. The guest gets keyboard input only through the VM's virtual
keyboard (`vmctl.py type`).

| File | What it is |
|---|---|
| `vmctl.py` | VM lifecycle, guest exec, user-window launches, screenshots, and the `e2e` runner |
| `watch_install.py` | Stall-aware watcher for the unattended Windows install (`vmctl.py create`) |
| `accept-arcturus.ps1` | Post-sign-in acceptance: in a new window, `arcturus` cds into the checkout and starts an authed Claude with extremis + superpowers |
| `probes/browser-open-methods.ps1` | Which URL-opening methods (Start-Process, `cmd start`, rundll32, explorer) produce a browser from this window |
| `probes/watch-new-processes.ps1` | Logs every new process and its parent for 45 s: what a CLI actually spawns |

**Open question (2026-11-21):** `claude auth login` (2.1.330) printed "Opening
browser to sign in…" but started no child process within 40 s. That was in a
shell-launched window in the VM, where rundll32 `url,OpenURL`, its Windows
opener, does open Edge. The run was confounded by an already-running Edge and
a frozen display. The sign-in still works by Ctrl+clicking the printed link.
To settle it, restore `fresh`, run `watch-new-processes.ps1`, and start
`claude auth login` from Start → PowerShell, with someone watching the VM.

Host requirements: VirtualBox 7.1+, Python 3.11+, about 70 GB free disk, a
Windows 11 ISO. Defaults: VM `bootstrap-test-win11` under `D:\VMs\bootstrap-test`
(override with `BT_VM` / `BT_VM_BASE`). Guest user is `tester`, with a throwaway
password for this loopback-only VM. Guest scratch dir: `C:\bt`.

## The everyday command

```bash
python tests/vm/vmctl.py e2e            # restore 'fresh', run the working-tree bootstrap.ps1, assert
python tests/vm/vmctl.py e2e --no-reset # same, on the VM as it is (tests the re-run path)
```

`e2e` restores the `fresh` snapshot. It runs the bootstrap in a real user
window with `BOOTSTRAP_STOP_BEFORE_SIGNIN=1`, which stops cleanly right before
the first sign-in. It then asserts that every pre-sign-in step reported
`changed` or `already satisfied`. It ends with `E2E-VERDICT PASS|FAIL` and
exit code 0 or 1. **No account or credential is involved.** Expect about
25 minutes; most of it is PortableGit unpacking on the VM's slow disk (see
gotchas).

The steps are ordered so the most work happens before that boundary. Before
any sign-in: execution policy, Git, git config, Python, Claude, gh, and the
PowerShell profile block, including a check that a new window actually runs
it. After the sign-ins: Claude auth, gh auth, repo clones, plugins, settings,
and the final "a new window defines `arcturus`" check. Keep new steps that
need no account above the boundary in `Main`.

### Covering the sign-in half

The sign-in steps need a real person to complete the Claude and GitHub OAuth
flows. Don't put personal work credentials into a VM an agent can reach. Do
the sign-in half on the real target machine, or with dedicated test accounts.
After a run that signs in, restore `fresh` again (`vmctl.py reset`); a
restore discards the whole disk and memory state, tokens included.

To finish a run by hand: `vmctl.py launch --name signin --command "iex (Get-Content -Raw C:\bt\bootstrap.ps1)"`.
Open VirtualBox Manager, select the VM, click **Show**, and complete the
sign-ins. Then run `vmctl.py launch --name accept --script tests/vm/accept-arcturus.ps1 --wait`
and look for `ACCEPT-VERDICT PASS`.

## Building the baseline image (once)

```bash
python tests/vm/vmctl.py create --iso <Win11.iso>   # unattended install; default key = generic Win11 Home
python tests/vm/watch_install.py                    # poll until the user logs in; flags stalls
python tests/vm/vmctl.py snapshot --name fresh --description "Win11 <build>, tester logged in, GA up, nothing bootstrapped"
```

The `fresh` snapshot is a *live* snapshot (with memory), so `reset` comes back
already logged in, in under a minute.

## Subcommands

| Command | Use |
|---|---|
| `create --iso` | Create the VM and start Windows' unattended install |
| `wait` | Block until Guest Additions report a logged-in user and guest exec works |
| `snapshot --name` / `reset --name` | Take a snapshot / restore one and boot it |
| `exec "<ps>"` | Run PowerShell in the guest. **Not** the user's desktop session; use it for inspection |
| `launch --name N (--command \| --script)` `[--wait]` | Run PowerShell in a real user window on the desktop. Transcript at `C:\bt\N.log`, `C:\bt\N.done` when finished. `--wait` streams the log and flags UAC prompts |
| `push` / `pull` | Copy files into or out of the guest |
| `gshot <png>` | Screenshot captured *inside* the user session (reliable) |
| `shot <png>` | VirtualBox screenshot (goes stale; see gotchas) |
| `type "<text>" --shot <png>` | Type into the focused guest window through the virtual keyboard |
| `status` | VM state, snapshots, UAC prompt showing |
| `e2e` | The pre-sign-in fresh-install test described above |

## Gotchas we paid for

Each of these cost real time on 2026-11-20/21; the harness already handles them.

**Launching a "real user" window**
- **Task Scheduler windows are not real user windows.** A window started by a
  scheduled task (even LogonType Interactive, RunLevel Limited) lives inside
  the Task Scheduler *job object*. A browser started from it comes up with one
  process and no window, so `claude auth login` and `gh auth login` look
  broken when they aren't. `launch` therefore uses the task only to run
  `explorer.exe C:\bt\<name>.cmd`. The running shell starts the window,
  outside the job, like Start → PowerShell. (Opening the window this way
  lands in Windows Terminal, as it does for a real user.)
- **Never pass `-ExecutionPolicy Bypass` (or `-File`) to the window under
  test.** It masks the fresh-machine default policy, `Restricted`, which is
  exactly what step 1 fixes. `launch` starts `powershell -NoExit -Command
  "iex (Get-Content -Raw launcher.ps1)"`, which is no more privileged than
  the user's `irm | iex`.

**Seeing what's on the screen**
- **`VBoxManage controlvm screenshotpng` goes stale** once the Guest
  Additions display driver loads: it keeps returning an old frame. Use
  `gshot`, which runs `CopyFromScreen` in the user session (after
  `SetProcessDPIAware`). The first capture can take about a minute while
  `Add-Type` compiles.
- **The guest display also sleeps.** When the taskbar clock in a screenshot
  stops matching `exec Get-Date`, the frame is frozen. Have someone click
  inside the VM window, or don't trust the image.
- **Edge relaunches itself** after `Stop-Process` ("closed unexpectedly →
  Restore"), and a URL handed to a running Edge opens a tab without any new
  process. Counting `msedge` processes is not a reliable "did a browser open"
  signal. Watch the opener's child processes instead: which process the CLI
  spawned, and with what command line.

**Waiting on the VM without being fooled**
- **Poll for stalls; never sleep blindly.** The unattended install can sit on
  the product-key page (fixed by `--key`), on "Press any key to boot from CD"
  (fixed by Enter scancodes), or hang after a reboot (fixed by `controlvm
  reset`). `watch_install.py` gates on the `LoggedInUsers` guest property and
  calls a stall when the VDI's size *and* mtime stop changing. Screenshot
  hashes don't work for this, because the spinner animates.
- **The VM reboots itself overnight** for Windows Update, killing in-flight
  runs. Re-run from `fresh`; don't debug a stale VM.
- **The current `fresh` snapshot carries a pending update.** A few minutes
  after a restore, Windows may install updates and restart. Sometimes it
  auto-logs `tester` back in, sometimes it stops at the sign-in screen
  (`vmctl.py type bootstrap-test` logs in). `e2e`/`reset` wait up to 15
  minutes for the guest, which absorbs the usual case; one run on
  2026-11-21 passed through it. To retire it, re-take `fresh` from a fully
  updated, idle, logged-in state, with no `RebootRequired` /
  `RebootPending` keys and no `C:\bt`. Budget an hour; a forced restart
  mid-servicing once left the guest unresponsive, and restoring `fresh`
  recovered it.
- **`LoggedInUsers` lies right after a restore.** It can read "No value set"
  while the guest is logged in and guest exec works. Trust a `vmctl.py exec`
  probe instead.
- **Killing `vmctl.py` (e.g. with `timeout`) orphans its `VBoxManage
  guestcontrol` child**, which holds a session lock. The next restore then
  fails with "already locked for a session". `reset` now retries, kills this
  VM's leftover harness processes, and as a last resort restarts `VBoxSVC`
  (only when no other VM is running).
- **This VM is slow** (VirtualBox on Hyper-V, NEM). Unpacking PortableGit
  (about 350 MB) takes about 15 minutes, mostly Defender scanning each file.
  A real PC takes about one minute. Slow is not a stall: check that the
  target folder keeps growing.

**Tooling**
- **Windows `cp1252` consoles crash Python** on guest transcripts (box
  drawing, U+FFFD). `vmctl.py` reconfigures stdout. Set
  `PYTHONIOENCODING=utf-8` in shells that pipe it.
- **The guest exec session is not elevated and not the desktop session.**
  WMI process-start traces need admin, so poll `Get-Process` for new PIDs
  and resolve parents with CIM instead.

## PowerShell 5.1 traps found by this harness

These are the bootstrap's own bugs, now fixed and recorded in the script
header. Check new code against them:

1. `$ErrorActionPreference='Stop'` plus native stderr redirection
   (`2>&1`, `2>$null`) gives a terminating NativeCommandError. Use
   `Invoke-Native`.
2. `& native` **inside a function whose result is assigned** sends the
   native program's stdout into the pipeline. The user never sees the
   sign-in URL or device code, and the tool sees a non-TTY stdout. Use
   `Start-Process -NoNewWindow` (`Invoke-Interactive`).
3. `Start-Process -Wait` waits for **every descendant**, so a browser the
   login opened would hold the step until it is closed. Use `-PassThru`,
   touch `.Handle`, then `.WaitForExit()`.
4. A function returning an empty array returns `$null`, and one returning a
   1-element array returns a bare item. Under StrictMode, `.Count` on
   `$null` throws. Wrap the call site in `@(...)`.
5. A bare `''` native argument is dropped. Pass `'""'` for an empty value.
6. Winget's `--scope user` for `Git.Git` still raises UAC. Git comes from
   the PortableGit SFX instead. Its system gitconfig sets
   `credential.helper=helper-selector`, which pops a picker dialog, so step 3
   puts a blank entry first and then `manager`.
7. `gh auth login` asks "Authenticate Git with your GitHub credentials?
   (Y/n)" unless git's github.com helper is already gh. Step 9 wires the
   helper before the login.
