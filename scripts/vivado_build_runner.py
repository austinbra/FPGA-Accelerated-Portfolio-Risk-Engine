#!/usr/bin/env python3
"""Launch Vivado batch builds with a clean Windows environment and timeout."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path


def tail_text(path: Path, max_lines: int = 80) -> str:
    if not path.exists():
        return ""
    lines = path.read_text(errors="replace").splitlines()
    return "\n".join(lines[-max_lines:])


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Robust Vivado launcher for repo build scripts.")
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--vivado", type=Path, required=True)
    parser.add_argument("--tcl-script", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=int, required=True)
    parser.add_argument("--log-file", type=Path, required=True)
    parser.add_argument("--synth-only", action="store_true")
    parser.add_argument("--multi-exercise", action="store_true")
    parser.add_argument("--clock-period-ns", type=str, default="")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo = args.repo.resolve()
    vivado = args.vivado.resolve()
    tcl_script = args.tcl_script.resolve()
    log_file = args.log_file.resolve()
    log_file.parent.mkdir(parents=True, exist_ok=True)

    env_root = repo / ".tmp" / "vivado_env"
    appdata = env_root / "appdata"
    localappdata = env_root / "localappdata"
    userprofile = env_root / "userprofile"
    tempdir = env_root / "temp"
    for path in (appdata, localappdata, userprofile, tempdir):
        path.mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    system_root = os.environ.get("SystemRoot", r"C:\Windows")
    vivado_bin = str(vivado.parent)
    env["SystemRoot"] = system_root
    env["ComSpec"] = os.environ.get("ComSpec", str(Path(system_root) / "System32" / "cmd.exe"))
    current_path = os.environ.get("Path") or os.environ.get("PATH") or ""
    env.pop("PATH", None)
    env["Path"] = os.pathsep.join(
        [vivado_bin, str(Path(system_root) / "System32"), system_root, current_path]
    )
    env["APPDATA"] = str(appdata)
    env["LOCALAPPDATA"] = str(localappdata)
    env["USERPROFILE"] = str(userprofile)
    env["TEMP"] = str(tempdir)
    env["TMP"] = str(tempdir)
    env["VIVADO_SYNTH_ONLY"] = "1" if args.synth_only else "0"
    env["VIVADO_MULTI_EXERCISE"] = "1" if args.multi_exercise else "0"
    if args.clock_period_ns:
        env["VIVADO_CLOCK_PERIOD_NS"] = args.clock_period_ns

    tclargs = []
    if args.synth_only:
        tclargs.append("--synth-only")
    if args.multi_exercise:
        tclargs.append("--multi-exercise")
    if args.clock_period_ns:
        tclargs.extend(["--clock-period-ns", args.clock_period_ns])

    cmd = [
        str(vivado),
        "-mode",
        "batch",
        "-source",
        str(tcl_script),
    ]
    if tclargs:
        cmd.extend(["-tclargs", *tclargs])

    start = time.time()
    command_line = " ".join(f'"{item}"' if " " in item else item for item in cmd)
    launch_cmd = [env["ComSpec"], "/d", "/c", command_line]

    with log_file.open("w", encoding="utf-8", errors="replace") as log:
        log.write("Command: " + " ".join(cmd) + "\n")
        log.flush()
        proc = subprocess.Popen(
            launch_cmd,
            cwd=repo,
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
            text=True,
            shell=False,
        )
        try:
            rc = proc.wait(timeout=args.timeout_seconds)
        except subprocess.TimeoutExpired:
            subprocess.run(
                ["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            # Vivado's Windows launcher can detach vivado.exe from the .bat/cmd
            # parent. On timeout, clean up stale Vivado processes so the next
            # run does not inherit a wedged background build.
            subprocess.run(
                ["taskkill", "/IM", "vivado.exe", "/F"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            subprocess.run(
                [
                    "powershell",
                    "-NoProfile",
                    "-NonInteractive",
                    "-Command",
                    "Stop-Process -Name vivado -Force -ErrorAction SilentlyContinue",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            elapsed = time.time() - start
            print(f"ERROR: Vivado timed out after {elapsed:.1f}s; killed PID tree rooted at {proc.pid}")
            print(f"Log: {log_file}")
            tail = tail_text(log_file)
            if tail:
                print("--- log tail ---")
                print(tail)
            return 124

    elapsed = time.time() - start
    print(f"Vivado exited with code {rc} after {elapsed:.1f}s")
    print(f"Log: {log_file}")
    if rc != 0:
        tail = tail_text(log_file)
        if tail:
            print("--- log tail ---")
            print(tail)
    return rc


if __name__ == "__main__":
    sys.exit(main())
