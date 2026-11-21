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
import shutil
import subprocess
import sys
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
        r = vbox("guestproperty", "get", VM, "/VirtualBox/GuestAdd/RunLevel", check=False)
        level = r.stdout.strip()
        if level != last:
            print(f"  guest additions: {level or 'n/a'}", flush=True)
            last = level
        if "Value: 3" in level:  # 3 = userland services up and a user is logged in
            probe = guest_run("$env:USERNAME", timeout_s=60, check=False)
            if probe.returncode == 0:
                print(f"ready (logged in as {probe.stdout.strip()})")
                return
        time.sleep(20)
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
    vbox("snapshot", VM, "restore", a.name)
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
    . '{dir}\{name}.body.ps1'
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
    launcher = LAUNCHER.format(dir=GUEST_DIR, name=name)
    # Stage files through a guest command (base64 avoids quoting pitfalls).
    stage = (
        f"New-Item -ItemType Directory -Force -Path '{GUEST_DIR}' | Out-Null;"
        f"Remove-Item -Force -ErrorAction SilentlyContinue '{GUEST_DIR}\\{name}.log','{GUEST_DIR}\\{name}.done';"
        f"[IO.File]::WriteAllBytes('{GUEST_DIR}\\{name}.body.ps1', [Convert]::FromBase64String('{base64.b64encode(body.encode('utf-8-sig')).decode()}'));"
        f"[IO.File]::WriteAllBytes('{GUEST_DIR}\\{name}.ps1', [Convert]::FromBase64String('{base64.b64encode(launcher.encode('utf-8-sig')).decode()}'));"
        # Interactive-only, LIMITED run level: shows a normal PowerShell window on the user's desktop.
        f"$a = New-ScheduledTaskAction -Execute '{PS}' -Argument '-NoExit -ExecutionPolicy Bypass -File {GUEST_DIR}\\{name}.ps1';"
        f"$p = New-ScheduledTaskPrincipal -UserId '{USER}' -LogonType Interactive -RunLevel Limited;"
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

    st = sub.add_parser("status")
    st.set_defaults(fn=cmd_status)

    a = p.parse_args(argv)
    a.fn(a)
    return 0


if __name__ == "__main__":
    sys.exit(main())
