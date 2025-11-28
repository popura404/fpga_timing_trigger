#!/usr/bin/env python3
"""Reproducible local entry point; generated files stay below build/."""
import os
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "sim"))
from regression import write_vectors


def executable(name):
    override = os.environ.get(name.upper())
    if override:
        if not Path(override).is_file():
            raise SystemExit(f"{name.upper()} does not name a file: {override}")
        return override
    candidates = [override, shutil.which(name), shutil.which(name + ".exe"),
                  f"/mnt/e/iverilog/bin/{name}.exe", f"E:/iverilog/bin/{name}.exe"]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return str(candidate)
    raise SystemExit(f"Cannot find {name}; set {name.upper()} to its executable path")


def tool_path(path, tool):
    if tool.endswith((".exe", ".bat")) and sys.platform != "win32":
        return subprocess.check_output(["wslpath", "-m", str(path)], text=True).strip()
    return str(path)


def run(command, cwd):
    print("+ " + " ".join(map(str, command)), flush=True)
    subprocess.run(command, cwd=cwd, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["sim"])
    parser.add_argument("--widths", choices=["all", "default", "small"], default="all")
    args = parser.parse_args()
    compiler = executable("iverilog")
    for name, widths in [("default", (32, 16, 32)), ("small", (4, 3, 3))]:
        if args.widths not in ("all", name):
            continue
        work = ROOT / "build" / "sim" / name
        work.mkdir(parents=True, exist_ok=True)
        count = write_vectors(work / "vectors.txt", *widths)
        print(f"{name}: {count} scheduled comparisons", flush=True)
        parameters = [f"-Ptb_timing_trigger.{key}={value}" for key, value in
                      zip(("TIME_W", "REPEAT_W", "COUNT_W"), widths)]
        run([compiler, "-g2012", "-Wall", "-s", "tb_timing_trigger", *parameters,
             "-o", "run.vvp", tool_path(ROOT / "rtl/timing_trigger.sv", compiler),
             tool_path(ROOT / "sim/tb_timing_trigger.sv", compiler)], work)
        run([executable("vvp"), "run.vvp"], work)


if __name__ == "__main__":
    main()
