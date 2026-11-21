#!/usr/bin/env python3
"""VirtualBox harness for end-to-end bootstrap testing on a fresh Windows 11 VM.

Subcommands:
  create      Create the VM and run Windows' unattended install from an ISO.
  wait        Block until Guest Additions report ready inside the VM.
  snapshot    Take the named snapshot (default: fresh).
  reset       Power off, restore the named snapshot, boot, wait for ready.
  exec        Run a PowerShell command inside the guest (non-interactive session).
  launch      Run a PowerShell script in the logged-on user's DESKTOP session,
              non-elevated, exactly as if the user had opened PowerShell and
              pasted it. Output is transcribed to C:\\bt\\<name>.log in the guest.
  pull        Copy a file out of the guest.
  status      Show VM state, snapshots, and whether a UAC prompt is pending.

Everything shells out to VBoxManage. Host-side only; no keystrokes are injected.
"""
from __future__ import annotations

import argparse
import base64
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

VBOX = os.environ.get("VBOXMANAGE") or shutil.which("VBoxManage") or r"C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
VM = os.environ.get("BT_VM", "bootstrap-test-win11")
BASE = Path(os.environ.get("BT_VM_BASE", r"D:\VMs\bootstrap-test"))
USER = "tester"
# Throwaway credential for a loopback-only test VM; not a secret of any value.
PASSWORD = "bootstrap-test"
GUEST_DIR = r"C:\bt"
PS = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"


def vbox(*args: str, check: bool = True, capture: bool = True, timeout: float | None = None) -> subprocess.CompletedProcess:
    cmd = [VBOX, *args]
    r = subprocess.run(cmd, capture_output=capture, text=True, encoding="utf-8", errors="replace", timeout=timeout)
    if check and r.returncode != 0:
        raise SystemExit(f"VBoxManage {' '.join(args[:3])} failed ({r.returncode}):\n{r.stdout}\n{r.stderr}")
    return r


def vm_state() -> str:
    r = vbox("showvminfo", VM, "--machinereadable", check=False)
    for line in r.stdout.splitlines():
        if line.startswith("VMState="):
            return line.split("=", 1)[1].strip('"')
    return "absent"


def guest_run(ps_command: str, timeout_s: int = 600, check: bool = True) -> subprocess.CompletedProcess:
    """Run PowerShell inside the guest via guestcontrol (service-launched, no desktop)."""
    ps_command = "$ProgressPreference='SilentlyContinue'; " + ps_command  # keep CLIXML progress out of stdout
    enc = base64.b64encode(ps_command.encode("utf-16-le")).decode()
    r = vbox(
        "guestcontrol", VM, "run",
        "--username", USER, "--password", PASSWORD,
        "--exe", PS, f"--timeout={timeout_s * 1000}", "--wait-stdout", "--wait-stderr",
        "--", "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-EncodedCommand", enc,
        check=False, timeout=timeout_s + 60,
    )
    if check and r.returncode != 0:
        raise SystemExit(f"guest command failed ({r.returncode}):\n{r.stdout}\n{r.stderr}")
    return r


def cmd_create(a: argparse.Namespace) -> None:
    if vm_state() != "absent":
        raise SystemExit(f"VM {VM} already exists; refusing to recreate. Delete it explicitly first.")
    iso = Path(a.iso).resolve()
    if not iso.is_file():
        raise SystemExit(f"ISO not found: {iso}")
    BASE.mkdir(parents=True, exist_ok=True)
    vbox("createvm", "--name", VM, "--ostype", "Windows11_64", "--basefolder", str(BASE), "--register")
    vbox("modifyvm", VM,
         "--memory", str(a.memory), "--cpus", str(a.cpus), "--vram", "128",
         "--firmware", "efi", "--tpm-type", "2.0",
         "--graphicscontroller", "vboxsvga", "--nic1", "nat",
         "--audio-enabled", "off", "--clipboard-mode", "disabled", "--drag-and-drop", "disabled",
         "--usb-xhci", "on")
    disk = BASE / VM / f"{VM}.vdi"
    vbox("createmedium", "disk", "--filename", str(disk), "--size", str(a.disk_gb * 1024), "--format", "VDI")
    vbox("storagectl", VM, "--name", "SATA", "--add", "sata", "--controller", "IntelAhci", "--portcount", "4")
    vbox("storageattach", VM, "--storagectl", "SATA", "--port", "0", "--device", "0", "--type", "hdd", "--medium", str(disk))
    vbox("unattended", "install", VM, f"--iso={iso}",
         f"--user={USER}", f"--user-password={PASSWORD}", f"--admin-password={PASSWORD}",
         "--full-user-name=Bootstrap Tester", f"--image-index={a.image_index}",
         # Microsoft's published generic install key for Windows 11 Home: selects the
         # edition so Setup doesn't stop on the product-key page; it does not activate.
         f"--key={a.key}",
         "--install-additions", "--locale=en_US", "--country=US", "--time-zone=Central Standard Time",
         f"--hostname={VM}.local", f"--start-vm={a.session}", capture=False)
    # Windows' EFI CD loader always shows "Press any key to boot from CD or DVD";
    # with no keypress it falls through to the blank disk. Tap Enter on the VM's
    # virtual keyboard (VirtualBox API -- never host input) for ~20s.
    for _ in range(14):
        vbox("controlvm", VM, "keyboardputscancode", "1c", "9c", check=False)
        time.sleep(1.5)
    print(f"created {VM}; unattended install running ({a.session}). Next: vmctl.py wait")


def wait_ready(timeout_s: int) -> None:
    deadline = time.time() + timeout_s
    last = ""
    while time.time() < deadline:
        # Readiness = VBoxService answers guestcontrol AND a user is logged in.
        # (GuestAdd/RunLevel isn't reliably published, so don't gate on it.)
        users = vbox("guestproperty", "get", VM, "/VirtualBox/GuestInfo/OS/LoggedInUsers", check=False).stdout.strip()
        if users != last:
            print(f"  logged-in users: {users or 'n/a'}", flush=True)
            last = users
        if users.startswith("Value:") and users != "Value: 0":
            probe = guest_run("$env:USERNAME", timeout_s=60, check=False)
            if probe.returncode == 0:
                print(f"ready (guestcontrol as {probe.stdout.strip()})")
                return
        time.sleep(30)
    raise SystemExit(f"timed out after {timeout_s}s waiting for {VM} to be ready")


def cmd_wait(a: argparse.Namespace) -> None:
    wait_ready(a.timeout)


def cmd_snapshot(a: argparse.Namespace) -> None:
    vbox("snapshot", VM, "take", a.name, "--description", a.description or "bootstrap-test baseline")
    print(f"snapshot {a.name} taken")


def cmd_reset(a: argparse.Namespace) -> None:
    if vm_state() in ("running", "paused", "stuck"):
        vbox("controlvm", VM, "poweroff", check=False)
        for _ in range(30):
            if vm_state() in ("poweroff", "aborted", "saved"):
                break
            time.sleep(2)
    # The session lock outlives the 'poweroff' state by a few seconds; restore refuses
    # with "already locked for a session" until it is released.
    for attempt in range(20):
        r = vbox("snapshot", VM, "restore", a.name, check=False)
        if r.returncode == 0:
            break
        if "locked" not in (r.stderr + r.stdout) or attempt == 19:
            raise SystemExit(f"snapshot restore failed:\n{r.stderr}")
        time.sleep(3)
    vbox("startvm", VM, "--type", a.session)
    wait_ready(a.timeout)


def cmd_exec(a: argparse.Namespace) -> None:
    r = guest_run(a.command, timeout_s=a.timeout, check=False)
    sys.stdout.write(r.stdout)
    sys.stderr.write(r.stderr)
    sys.exit(r.returncode)


LAUNCHER = r"""
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path '{dir}' | Out-Null
Start-Transcript -Path '{dir}\{name}.log' -Force | Out-Null
try {{
    # The body arrives inline (never dot-sourced from a file) so the window keeps
    # the user's REAL execution policy -- a -File/-ExecutionPolicy Bypass launch
    # would mask exactly the fresh-machine failures we're testing for.
    Invoke-Expression ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{body_b64}')))
}} catch {{
    Write-Host "LAUNCHER CAUGHT: $($_.Exception.Message)" -ForegroundColor Red
}} finally {{
    Write-Host "BT-LAUNCH-DONE {name}"
    Stop-Transcript | Out-Null
    Set-Content -Path '{dir}\{name}.done' -Value (Get-Date -Format o)
}}
"""


def cmd_launch(a: argparse.Namespace) -> None:
    """Run a script in the user's interactive desktop session, non-elevated."""
    body = Path(a.script).read_text(encoding="utf-8") if a.script else a.command
    name = a.name
    launcher = LAUNCHER.format(dir=GUEST_DIR, name=name, body_b64=base64.b64encode(body.encode("utf-8")).decode())
    guest_run(f"New-Item -ItemType Directory -Force -Path '{GUEST_DIR}' | Out-Null", timeout_s=60)
    with tempfile.TemporaryDirectory() as td:
        lp = Path(td) / f"{name}.launcher.ps1"
        lp.write_text(launcher, encoding="utf-8-sig")
        cp = Path(td) / f"{name}.cmd"
        # The window starts with NO policy override and NO -NoProfile, exactly like the
        # user opening a new PowerShell. iex of file text is not policy-gated (same as irm|iex).
        cp.write_text(
            f'@start "" "{PS}" -NoExit -Command "iex (Get-Content -Raw \'{GUEST_DIR}\\{name}.launcher.ps1\')"\r\n',
            encoding="ascii",
        )
        for f in (lp, cp):
            vbox("guestcontrol", VM, "copyto", "--username", USER, "--password", PASSWORD,
                 str(f), f"{GUEST_DIR}\\{f.name}")
    stage = (
        f"Remove-Item -Force -ErrorAction SilentlyContinue '{GUEST_DIR}\\{name}.log','{GUEST_DIR}\\{name}.done';"
        # A scheduled task (Interactive, LIMITED) only KICKS the launch: it asks the
        # user's running Explorer to open the .cmd, so the PowerShell window is a child
        # of the real shell. Launching the window from the task directly puts it in the
        # Task Scheduler job object, where browsers start windowless -- `claude auth
        # login` / `gh auth login` then look broken when they aren't (proven 2026-11-21).
        f"$a = New-ScheduledTaskAction -Execute 'explorer.exe' -Argument '{GUEST_DIR}\\{name}.cmd';"
        f"$p = New-ScheduledTaskPrincipal -UserId '{USER}' -LogonType Interactive -RunLevel Limited;"
        # A still-running -NoExit instance makes Start-ScheduledTask a silent no-op (0x800710E0).
        f"Stop-ScheduledTask -TaskName 'bt-{name}' -ErrorAction SilentlyContinue;"
        f"Register-ScheduledTask -TaskName 'bt-{name}' -Action $a -Principal $p -Force | Out-Null;"
        f"Start-ScheduledTask -TaskName 'bt-{name}';"
        "'launched'"
    )
    r = guest_run(stage, timeout_s=120)
    print(r.stdout.strip())
    if not a.wait:
        return
    deadline = time.time() + a.timeout
    seen = 0
    uac_reported = False
    while time.time() < deadline:
        time.sleep(15)
        probe = guest_run(
            f"$d = Test-Path '{GUEST_DIR}\\{name}.done';"
            f"$u = [bool](Get-Process consent -ErrorAction SilentlyContinue);"
            f"$l = if (Test-Path '{GUEST_DIR}\\{name}.log') {{ (Get-Content -Raw '{GUEST_DIR}\\{name}.log') }} else {{ '' }};"
            "\"DONE=$d UAC=$u\"; '---'; $l",
            timeout_s=60, check=False,
        )
        out = probe.stdout
        head, _, log = out.partition("---")
        new = log[seen:] if len(log) >= seen else log
        if new.strip():
            sys.stdout.write(new)
            sys.stdout.flush()
        seen = len(log)
        if "UAC=True" in head and not uac_reported:
            print("\n!! UAC consent prompt is showing on the guest desktop", flush=True)
            uac_reported = True
        if "DONE=True" in head:
            print(f"\n[{name}] finished")
            return
    raise SystemExit(f"[{name}] did not finish within {a.timeout}s")


def cmd_push(a: argparse.Namespace) -> None:
    guest_run(f"New-Item -ItemType Directory -Force -Path (Split-Path '{a.dest}') | Out-Null", timeout_s=60)
    vbox("guestcontrol", VM, "copyto", "--username", USER, "--password", PASSWORD,
         str(Path(a.src).resolve()), a.dest, capture=False)
    print(f"copied {a.src} -> {a.dest}")


def cmd_type(a: argparse.Namespace) -> None:
    """Type a line into the focused guest window via the VM's virtual keyboard, then
    screenshot after --settle seconds. Guest input only; the host is never touched."""
    vbox("controlvm", VM, "keyboardputstring", a.text)
    vbox("controlvm", VM, "keyboardputscancode", "1c", "9c")  # Enter
    time.sleep(a.settle)
    Path(a.shot).parent.mkdir(parents=True, exist_ok=True)
    vbox("controlvm", VM, "screenshotpng", str(Path(a.shot).resolve()))
    print(f"typed {a.text!r}; screenshot {a.shot}")


def cmd_shot(a: argparse.Namespace) -> None:
    Path(a.path).parent.mkdir(parents=True, exist_ok=True)
    vbox("controlvm", VM, "screenshotpng", str(Path(a.path).resolve()))
    print(a.path)


GSHOT = r"""
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace BT -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][BT.Dpi]::SetProcessDPIAware()
$b = [Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object Drawing.Bitmap $b.Width, $b.Height
$g = [Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
$bmp.Save('{dir}\gshot.tmp.png', [Drawing.Imaging.ImageFormat]::Png)
Move-Item -Force '{dir}\gshot.tmp.png' '{dir}\gshot.png'
"""


def cmd_gshot(a: argparse.Namespace) -> None:
    """Capture the guest desktop from INSIDE the user session. VBoxManage screenshotpng
    goes stale once the GA display driver loads; this one never does."""
    enc = base64.b64encode(GSHOT.format(dir=GUEST_DIR).encode("utf-16-le")).decode()
    stage = (
        f"Remove-Item -Force -ErrorAction SilentlyContinue '{GUEST_DIR}\\gshot.png';"
        f"$a = New-ScheduledTaskAction -Execute '{PS}' -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand {enc}';"
        f"$p = New-ScheduledTaskPrincipal -UserId '{USER}' -LogonType Interactive -RunLevel Limited;"
        "Register-ScheduledTask -TaskName 'bt-gshot' -Action $a -Principal $p -Force | Out-Null;"
        "Start-ScheduledTask -TaskName 'bt-gshot';"
        f"foreach ($i in 1..180) {{ if (Test-Path '{GUEST_DIR}\\gshot.png') {{ 'captured'; break }}; Start-Sleep 1 }}"
    )
    r = guest_run(stage, timeout_s=240)
    if "captured" not in r.stdout:
        raise SystemExit("guest screenshot not produced within 180s")
    Path(a.path).parent.mkdir(parents=True, exist_ok=True)
    vbox("guestcontrol", VM, "copyfrom", "--username", USER, "--password", PASSWORD,
         f"{GUEST_DIR}\\gshot.png", str(Path(a.path).resolve()), capture=False)
    print(a.path)


PRESIGNIN_STEPS = ["execution policy", "git", "git config", "python", "claude", "gh", "repo shortcuts"]


def cmd_e2e(a: argparse.Namespace) -> None:
    """Unattended fresh-install e2e of every step that needs no account: restore the
    snapshot, run the given bootstrap with BOOTSTRAP_STOP_BEFORE_SIGNIN=1 in a real
    user window, then assert each pre-sign-in step reported changed/already-satisfied
    and the run stopped at the sign-in boundary. Exit 0 = PASS."""
    if not a.no_reset:
        cmd_reset(argparse.Namespace(name=a.snapshot, session=a.session, timeout=900))
    src = Path(a.bootstrap).resolve()
    guest_run(f"New-Item -ItemType Directory -Force -Path '{GUEST_DIR}' | Out-Null", timeout_s=60)
    vbox("guestcontrol", VM, "copyto", "--username", USER, "--password", PASSWORD, str(src), f"{GUEST_DIR}\\bootstrap.ps1")
    started = time.time()
    cmd_launch(argparse.Namespace(
        name=a.name, script=None, wait=True, timeout=a.timeout,
        command=f"$env:BOOTSTRAP_STOP_BEFORE_SIGNIN = '1'; iex (Get-Content -Raw '{GUEST_DIR}\\bootstrap.ps1')",
    ))
    log = guest_run(f"Get-Content -Raw '{GUEST_DIR}\\{a.name}.log'", timeout_s=60).stdout
    results = {m.group(1).strip(): m.group(2) for m in
               re.finditer(r"^\[\d+/\d+\] (.+?)\s+\.\.\.\s*(changed|already satisfied|FAILED)", log, re.M)}
    ok = True
    for step in PRESIGNIN_STEPS:
        status = results.get(step)
        good = status in ("changed", "already satisfied")
        ok &= good
        print(f"E2E-{'OK  ' if good else 'FAIL'} {step:<18} {status or 'NOT REACHED'}")
    stopped = "BOOTSTRAP_STOP_BEFORE_SIGNIN=1: stopped before step" in log
    ok &= stopped
    print(f"E2E-{'OK  ' if stopped else 'FAIL'} {'stopped at sign-in':<18} {'yes' if stopped else 'no'}")
    print(f"E2E-VERDICT {'PASS' if ok else 'FAIL'} ({int(time.time() - started)}s run)")
    if not ok:
        sys.exit(1)


def cmd_pull(a: argparse.Namespace) -> None:
    Path(a.dest).parent.mkdir(parents=True, exist_ok=True)
    vbox("guestcontrol", VM, "copyfrom", "--username", USER, "--password", PASSWORD,
         a.src, a.dest, capture=False)


def cmd_status(a: argparse.Namespace) -> None:
    print(f"vm={VM} state={vm_state()}")
    r = vbox("snapshot", VM, "list", check=False)
    print(r.stdout.strip() or r.stderr.strip())
    if vm_state() == "running":
        u = guest_run("[bool](Get-Process consent -ErrorAction SilentlyContinue)", timeout_s=60, check=False)
        print(f"uac_prompt_showing={u.stdout.strip()}")


def main(argv: list[str] | None = None) -> int:
    # Guest transcripts carry non-cp1252 text (box-drawing, U+FFFD); never crash on output.
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("create")
    c.add_argument("--iso", required=True)
    c.add_argument("--image-index", type=int, default=1, help="WIM index (see `VBoxManage unattended detect`)")
    c.add_argument("--key", default="YTMG3-N6DKC-DKB77-7M9GH-8HVX7", help="generic install key (default: Win11 Home)")
    c.add_argument("--memory", type=int, default=8192)
    c.add_argument("--cpus", type=int, default=4)
    c.add_argument("--disk-gb", type=int, default=64)
    c.add_argument("--session", default="separate", help="headless | separate | gui")
    c.set_defaults(fn=cmd_create)

    w = sub.add_parser("wait")
    w.add_argument("--timeout", type=int, default=5400)
    w.set_defaults(fn=cmd_wait)

    s = sub.add_parser("snapshot")
    s.add_argument("--name", default="fresh")
    s.add_argument("--description")
    s.set_defaults(fn=cmd_snapshot)

    r = sub.add_parser("reset")
    r.add_argument("--name", default="fresh")
    r.add_argument("--session", default="separate")
    r.add_argument("--timeout", type=int, default=900)
    r.set_defaults(fn=cmd_reset)

    e = sub.add_parser("exec")
    e.add_argument("command")
    e.add_argument("--timeout", type=int, default=600)
    e.set_defaults(fn=cmd_exec)

    l = sub.add_parser("launch")
    g = l.add_mutually_exclusive_group(required=True)
    g.add_argument("--script")
    g.add_argument("--command")
    l.add_argument("--name", default="run")
    l.add_argument("--wait", action="store_true")
    l.add_argument("--timeout", type=int, default=3600)
    l.set_defaults(fn=cmd_launch)

    pl = sub.add_parser("pull")
    pl.add_argument("src")
    pl.add_argument("dest")
    pl.set_defaults(fn=cmd_pull)

    pu = sub.add_parser("push")
    pu.add_argument("src")
    pu.add_argument("dest")
    pu.set_defaults(fn=cmd_push)

    ty = sub.add_parser("type")
    ty.add_argument("text")
    ty.add_argument("--shot", required=True)
    ty.add_argument("--settle", type=int, default=30)
    ty.set_defaults(fn=cmd_type)

    sh = sub.add_parser("shot")
    sh.add_argument("path")
    sh.set_defaults(fn=cmd_shot)

    gs = sub.add_parser("gshot", help="screenshot from inside the guest session (never stale)")
    gs.add_argument("path")
    gs.set_defaults(fn=cmd_gshot)

    ee = sub.add_parser("e2e", help="unattended fresh-install run up to the first sign-in, with assertions")
    ee.add_argument("--bootstrap", default=str(Path(__file__).resolve().parents[2] / "bootstrap.ps1"))
    ee.add_argument("--snapshot", default="fresh")
    ee.add_argument("--session", default="separate")
    ee.add_argument("--name", default="e2e")
    ee.add_argument("--timeout", type=int, default=5400)
    ee.add_argument("--no-reset", action="store_true", help="run on the VM as-is (tests the re-run path)")
    ee.set_defaults(fn=cmd_e2e)

    st = sub.add_parser("status")
    st.set_defaults(fn=cmd_status)

    a = p.parse_args(argv)
    a.fn(a)
    return 0


if __name__ == "__main__":
    sys.exit(main())
