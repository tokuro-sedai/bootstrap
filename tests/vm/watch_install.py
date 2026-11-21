#!/usr/bin/env python3
"""Poll a VM during unattended install; print a line only on events worth acting on.

Events: guest-additions run-level change, ready (exits 0), VM not running (exits 1),
and POSSIBLE_STALL when the VM's disk image hasn't grown for --stall-polls polls.
(Screenshot hashes don't work as a stall signal: Setup's spinner animates forever,
even on a frozen percentage or a dialog waiting for input.)
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

VBOX = r"C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"


def run(*args: str) -> str:
    r = subprocess.run([VBOX, *args], capture_output=True, text=True, errors="replace")
    return (r.stdout or "") + (r.stderr or "")


def disk_activity(vm: str) -> tuple[int, float]:
    """(total bytes, newest mtime) over the VM's disk images.

    mtime matters as much as size: writes into already-allocated blocks
    don't grow a dynamic VDI.
    """
    info = run("showvminfo", vm, "--machinereadable")
    for line in info.splitlines():
        if line.startswith('"SATA-0-0"='):
            folder = Path(line.split("=", 1)[1].strip('"')).parent.parent  # VM folder (covers Snapshots/)
            files = list(folder.rglob("*.vdi"))
            return sum(f.stat().st_size for f in files), max((f.stat().st_mtime for f in files), default=0.0)
    return 0, 0.0


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--vm", default="bootstrap-test-win11")
    p.add_argument("--interval", type=int, default=120)
    p.add_argument("--stall-polls", type=int, default=3)
    p.add_argument("--shot", required=True, help="where to write the latest screenshot")
    a = p.parse_args()

    last_level, last_size, same = None, None, 0
    while True:
        info = run("showvminfo", a.vm, "--machinereadable")
        state = next((l.split("=", 1)[1].strip('"') for l in info.splitlines() if l.startswith("VMState=")), "absent")
        if state != "running":
            print(f"VM_NOT_RUNNING state={state}", flush=True)
            return 1
        level = run("guestproperty", "get", a.vm, "/VirtualBox/GuestInfo/OS/LoggedInUsers").strip()
        if level != last_level:
            print(f"LOGGED_IN_USERS {level}", flush=True)
            last_level = level
        if level.startswith("Value:") and level != "Value: 0":
            print("READY VBoxService up and a user is logged in", flush=True)
            return 0
        run("controlvm", a.vm, "screenshotpng", a.shot)
        size, mtime = disk_activity(a.vm)
        same = same + 1 if (size, mtime) == last_size else 0
        last_size = (size, mtime)
        if same == a.stall_polls:
            print(f"POSSIBLE_STALL no disk writes for {same * a.interval}s ({size / 2**30:.2f} GiB); see {a.shot}", flush=True)
        time.sleep(a.interval)


if __name__ == "__main__":
    sys.exit(main())
