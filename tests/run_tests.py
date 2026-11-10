#!/usr/bin/env python3
"""Runs the GDScript tests in parallel: one headless Godot per test file
(tests/run_tests.gd -- <file>), several at once.

    python3 tests/run_tests.py [filter] [--godot=GODOT] [-j N]

Each Godot gets its own user data folder (XDG_DATA_HOME under
.godot/test_data/<n>), so test worlds and settings never meet another
process's (or yours). Files that took longest last time start first
(.godot/test_times.json). Exits with 1 if anything failed.
"""

import argparse
import json
import os
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TIMES = ROOT / ".godot" / "test_times.json"
SUMMARY = re.compile(r"^(\d+) passed, (\d+) failed", re.M)


def find_godot(given: str | None) -> str:
    for g in [given, os.environ.get("GODOT"), "godot4", "godot"]:
        if g and (Path(g).is_file() or shutil.which(g)):
            return g
    sys.exit("No Godot found: pass --godot=PATH or set GODOT")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run GoCube's tests in parallel.")
    parser.add_argument("filter", nargs="?", default="", help="only test files whose name contains this")
    parser.add_argument("--godot", help="the Godot binary (default: $GODOT, godot4, godot)")
    parser.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 2)
    args = parser.parse_args()
    godot = find_godot(args.godot)

    files = sorted(f.name for f in (ROOT / "tests").glob("test_*.gd")
                   if f.name != "test_suite.gd" and args.filter in f.name)
    if not files:
        sys.exit(f"No test files match '{args.filter}'")
    try:
        times = json.loads(TIMES.read_text())
    except (OSError, ValueError):
        times = {}
    files.sort(key=lambda f: -times.get(f, 1000.0))  # new files count as slow

    slots: queue.Queue[int] = queue.Queue()
    for n in range(min(args.jobs, len(files))):
        slots.put(n)
    print_lock = threading.Lock()
    totals = {"passed": 0, "failed": 0}
    failed_files = []

    def run(file: str) -> None:
        slot = slots.get()
        try:
            env = dict(os.environ, XDG_DATA_HOME=str(ROOT / ".godot" / "test_data" / str(slot)))
            t0 = time.monotonic()
            proc = subprocess.run([godot, "--headless", "--path", str(ROOT), "-s", "res://tests/run_tests.gd",
                                   "--", file], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  text=True, errors="replace")
            times[file] = time.monotonic() - t0
        finally:
            slots.put(slot)
        out = proc.stdout
        lines = [l for l in out.splitlines() if l.startswith(("PASS", "FAIL", "        - "))]
        found = SUMMARY.search(out)
        passed, failed = (int(found[1]), int(found[2])) if found else (0, 1)
        with print_lock:
            totals["passed"] += passed
            totals["failed"] += failed
            if found is None or (proc.returncode != 0 and failed == 0):  # crashed or hung up
                failed_files.append(file)
                lines.append(f"FAIL  {file}: Godot exited with {proc.returncode}; its last output:")
                lines += ["        " + l for l in out.splitlines()[-15:]]
            elif failed:
                failed_files.append(file)
            print("\n".join(lines), flush=True)

    t_all = time.monotonic()
    with ThreadPoolExecutor(max_workers=min(args.jobs, len(files))) as pool:
        list(pool.map(run, files))  # (re-raises a runner error)
    TIMES.parent.mkdir(exist_ok=True)
    TIMES.write_text(json.dumps(times, indent=1, sort_keys=True))
    print(f"\n{totals['passed']} passed, {totals['failed']} failed ({time.monotonic() - t_all:.1f} s, "
          f"{len(files)} files, {min(args.jobs, len(files))} at a time)")
    if failed_files:
        print("Failed in:", ", ".join(failed_files))
    return 1 if totals["failed"] or failed_files else 0


if __name__ == "__main__":
    sys.exit(main())
