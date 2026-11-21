#!/usr/bin/env python3
"""Poll a VM during unattended install; print a line only on events worth acting on.

Events: guest-additions run-level change, ready (exits 0), VM not running (exits 1),
screen unchanged for --stall-polls consecutive polls (possible stall; keeps watching).
"""
from __future__ import annotations

import argparse
import hashlib
import subprocess
import sys
import time
from pathlib import Path

VBOX = r"C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"


def run(*args: str) -> str:
    r = subprocess.run([VBOX, *args], capture_output=True, text=True, errors="replace")
    return (r.stdout or "") + (r.stderr or "")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--vm", default="bootstrap-test-win11")
    p.add_argument("--interval", type=int, default=120)
    p.add_argument("--stall-polls", type=int, default=3)
    p.add_argument("--shot", required=True, help="where to write the latest screenshot")
    a = p.parse_args()

    last_level, last_hash, same = None, None, 0
    while True:
        info = run("showvminfo", a.vm, "--machinereadable")
        state = next((l.split("=", 1)[1].strip('"') for l in info.splitlines() if l.startswith("VMState=")), "absent")
        if state != "running":
            print(f"VM_NOT_RUNNING state={state}", flush=True)
            return 1
        level = run("guestproperty", "get", a.vm, "/VirtualBox/GuestAdd/RunLevel").strip()
        if level != last_level:
            print(f"RUNLEVEL {level}", flush=True)
            last_level = level
        if "Value: 3" in level:
            print("READY guest additions up and user logged in", flush=True)
            return 0
        run("controlvm", a.vm, "screenshotpng", a.shot)
        try:
            h = hashlib.sha256(Path(a.shot).read_bytes()).hexdigest()
        except OSError:
            h = None
        same = same + 1 if h and h == last_hash else 0
        last_hash = h
        if same == a.stall_polls:
            print(f"POSSIBLE_STALL screen unchanged for {same * a.interval}s; see {a.shot}", flush=True)
        time.sleep(a.interval)


if __name__ == "__main__":
    sys.exit(main())
