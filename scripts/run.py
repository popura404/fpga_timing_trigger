#!/usr/bin/env python3
"""Reproducible local entry point; generated files stay below build/."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "sim"))
from regression import write_vectors, write_comparison_vectors


def executable(name):
    override = os.environ.get(name.upper())
    if override:
        if not Path(override).is_file():
            raise SystemExit(f"{name.upper()} does not name a file: {override}")
        return str(Path(override).resolve())
    candidates = [shutil.which(name), shutil.which(name + ".exe"), shutil.which(name + ".bat"),
                  f"/mnt/e/iverilog/bin/{name}.exe", f"E:/iverilog/bin/{name}.exe"]
    if name == "vivado":
        candidates += ["/mnt/e/AMDDesignTools/2025.2/Vivado/bin/vivado.bat",
                       "E:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat"]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return str(Path(candidate).resolve())
    raise SystemExit(f"Cannot find {name}; set {name.upper()} to its executable path")


def tool_path(path, tool):
    if tool.lower().endswith((".exe", ".bat")) and sys.platform != "win32":
        return subprocess.check_output(["wslpath", "-m", str(path)], text=True).strip()
    return str(path)


def run(command, cwd):
    print("+ " + " ".join(map(str, command)), flush=True)
    subprocess.run(command, cwd=cwd, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    sim = actions.add_parser("sim", help="Independent cycle-by-cycle regression")
    sim.add_argument("--widths", choices=["all", "default", "small"], default="all")
    sim.add_argument("--compare-fixed", action="store_true",
                     help="Check generated fixed baseline and configurable RTL against the same schedule")
    implement = actions.add_parser("implement", help="Device-only OOC implementation, no bitstream")
    implement.add_argument("--mode", choices=["configurable", "fixed", "both"], default="configurable")
    args = parser.parse_args()
    if args.action == "implement":
        vivado = executable("vivado")
        for mode in (["configurable", "fixed"] if args.mode == "both" else [args.mode]):
            work = ROOT / "build" / "vivado" / mode
            work.mkdir(parents=True, exist_ok=True)
            command = [tool_path(Path(vivado), vivado), "-mode", "batch", "-source",
                       tool_path(ROOT / "scripts/implement.tcl", vivado), "-nojournal",
                       "-log", "vivado.log", "-tclargs", mode]
            if vivado.lower().endswith(".bat"):
                command = [shutil.which("cmd.exe") or "cmd.exe", "/d", "/c", *command]
            run(command, work)
        return
    compiler = executable("iverilog")
    variants = [("default", (32, 16, 32)), ("small", (4, 3, 3))]
    fixed_source = ROOT / "build/vivado/fixed/fixed_top.sv"
    if args.compare_fixed:
        if not fixed_source.is_file():
            raise SystemExit("First generate the baseline: python scripts/run.py implement --mode fixed")
        variants = [("comparison-configurable", (32, 16, 32)), ("comparison-fixed", (32, 16, 32))]
    for name, widths in variants:
        if not args.compare_fixed and args.widths not in ("all", name):
            continue
        work = ROOT / "build" / "sim" / name
        work.mkdir(parents=True, exist_ok=True)
        count = (write_comparison_vectors(work / "vectors.txt") if args.compare_fixed else
                 write_vectors(work / "vectors.txt", *widths))
        print(f"{name}: {count} scheduled comparisons", flush=True)
        parameters = [f"-Ptb_timing_trigger.{key}={value}" for key, value in
                      zip(("TIME_W", "REPEAT_W", "COUNT_W"), widths)]
        extra = (["-DFIXED_BASELINE", tool_path(fixed_source, compiler)]
                 if name == "comparison-fixed" else [])
        run([compiler, "-g2012", "-Wall", "-s", "tb_timing_trigger", *parameters,
             "-o", "run.vvp", *extra, tool_path(ROOT / "rtl/timing_trigger.sv", compiler),
             tool_path(ROOT / "sim/tb_timing_trigger.sv", compiler)], work)
        run([executable("vvp"), "run.vvp"], work)


if __name__ == "__main__":
    main()
