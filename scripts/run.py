#!/usr/bin/env python3
"""Reproducible local entry point; generated files stay below build/."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "sim"))
from regression import write_vectors


def executable(name):
    override = os.environ.get(name.upper())
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
    if sys.argv[1:] != ["sim"]:
        raise SystemExit("Usage: python scripts/run.py sim")
    work = ROOT / "build" / "sim"
    work.mkdir(parents=True, exist_ok=True)
    write_vectors(work / "vectors.txt")
    compiler = executable("iverilog")
    run([compiler, "-g2012", "-Wall", "-s", "tb_timing_trigger", "-o", "run.vvp",
         tool_path(ROOT / "rtl/timing_trigger.sv", compiler),
         tool_path(ROOT / "sim/tb_timing_trigger.sv", compiler)], work)
    run([executable("vvp"), "run.vvp"], work)


if __name__ == "__main__":
    main()
