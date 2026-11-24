#!/usr/bin/env python3
"""Measure Gary's frame pacing per scenario, alternating builds.

Run it from the repository root with two or more bundled apps:

    tools/frame-bench/frame-bench.py widget-menu main=/path/A/Gary.app branch=build/Gary.app --runs 6

Each run starts the build in a fresh isolated home under tmp/frame-bench, loads the
scenario's plugins, records `gary frames --record <seconds>` while it summons and
hides the menu, and stops Gary. Runs alternate between the builds, so drift in the
machine's load spreads over both. It prints each run, then the median and spread of
the hitch time in ms per second per build, with the load average.
"""

import argparse
import json
import os
import pathlib
import re
import shutil
import statistics
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = ROOT / "tools/frame-bench"
OUT = ROOT / "tmp/frame-bench"

SCENARIOS = {
    "widget-menu": {"counters": [1], "menu": True},
    "menu": {"counters": [], "menu": True},
    "widgets-menu": {"counters": [1000] * 16, "menu": True},
    "static": {"counters": [], "menu": False},
}


def gary(app):
    return pathlib.Path(app) / "Contents/MacOS/gary"


def make_home(home, scenario):
    shutil.rmtree(home, ignore_errors=True)
    plugins = home / ".config/gary/plugins"
    plugins.mkdir(parents=True)
    support = home / "Library/Application Support/Gary"
    support.mkdir(parents=True)
    (home / "Library/Logs").mkdir(parents=True)
    (home / "run").mkdir()
    (support / "onboarding.json").write_text('{ "missing": [] }\n')
    ids = []
    for index, every in enumerate(scenario["counters"]):
        plugin_id = f"bench.counter{index}"
        dst = plugins / plugin_id
        shutil.copytree(HERE / "plugins/counter", dst)
        (dst / "every.js").write_text(f"export const every = {every};\n")
        manifest = (dst / "manifest.json").read_text().replace('"bench.counter"', f'"{plugin_id}"')
        (dst / "manifest.json").write_text(manifest)
        ids.append(plugin_id)
    if scenario["menu"]:
        shutil.copytree(HERE / "plugins/menu", plugins / "bench.menu")
    shell = {
        "bar": {"right": ids},
        "plugins": ["bench.menu"] if scenario["menu"] else [],
        "disabledPlugins": ["gary.battery", "gary.clock", "gary.onboarding"],
    }
    (home / ".config/gary/shell.json").write_text(json.dumps(shell))


def call(app, env, *args, timeout=60):
    return subprocess.run([gary(app), *args], env=env, capture_output=True, text=True, timeout=timeout)


def hitch_ratio(report):
    best = None
    for match in re.finditer(r"at (\d+) Hz: [^,]+, ([\d.]+) ms of hitches per second", report):
        rate, ratio = int(match.group(1)), float(match.group(2))
        if best is None or rate > best[0]:
            best = (rate, ratio)
    return best[1] if best else None


def run(name, app, scenario, args, index):
    home = OUT / f"{name}-{index}"
    make_home(home, SCENARIOS[scenario])
    env = {**os.environ, "GARY_HOME": str(home), "GARY_RUNTIME_DIR": str(home / "run")}
    for pair in args.env:
        key, _, value = pair.partition("=")
        env[key] = value
    log = open(home / "stdout.log", "w")
    process = subprocess.Popen([gary(app)], env=env, stdout=log, stderr=subprocess.STDOUT)
    try:
        deadline = time.time() + 30
        while call(app, env, "ping").returncode != 0:
            if time.time() > deadline or process.poll() is not None:
                raise RuntimeError(f"{name} did not start, see {home}/stdout.log")
            time.sleep(0.2)
        time.sleep(args.settle)
        load = os.getloadavg()[0]
        trace = None
        if args.instruments and index == 0:
            output = OUT / f"{name}.trace"
            shutil.rmtree(output, ignore_errors=True)
            trace = subprocess.Popen(
                ["xcrun", "xctrace", "record", "--template", "Animation Hitches", "--all-processes",
                 "--time-limit", f"{args.record + 8:.0f}s", "--output", str(output)],
                stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT,
            )
            time.sleep(3)
        frames = subprocess.Popen(
            [gary(app), "frames", "--record", str(args.record)], env=env, stdout=subprocess.PIPE, text=True
        )
        time.sleep(1)
        if SCENARIOS[scenario]["menu"]:
            for _ in range(args.cycles):
                summoned = call(app, env, "summon", "bench.menu")
                if summoned.returncode != 0:
                    raise RuntimeError(f"summon failed: {summoned.stderr.strip()}")
                time.sleep(args.dwell)
                call(app, env, "hide", "bench.menu")
                time.sleep(args.dwell)
        report, _ = frames.communicate(timeout=args.record + 30)
        (home / "frames.txt").write_text(report)
        if trace:
            trace.wait(timeout=120)
        return hitch_ratio(report), load, report
    finally:
        call(app, env, "quit", timeout=10)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("scenario", choices=sorted(SCENARIOS))
    parser.add_argument("builds", nargs="+", metavar="name=Gary.app")
    parser.add_argument("--runs", type=int, default=5, help="runs per build")
    parser.add_argument("--record", type=float, default=16, help="seconds recorded per run")
    parser.add_argument("--cycles", type=int, default=7, help="menu summons per run")
    parser.add_argument("--dwell", type=float, default=0.9, help="seconds the menu stays shown, then hidden")
    parser.add_argument("--settle", type=float, default=3, help="seconds between start and recording")
    parser.add_argument("--env", action="append", default=[], metavar="KEY=VALUE", help="extra environment for Gary")
    parser.add_argument("--instruments", action="store_true", help="record the first run of each build with Animation Hitches")
    parser.add_argument("--verbose", action="store_true", help="print each run's full report")
    args = parser.parse_args()
    builds = [build.split("=", 1) for build in args.builds]
    results = {name: [] for name, _ in builds}
    loads = []
    for index in range(args.runs):
        for name, app in builds if index % 2 == 0 else reversed(builds):
            ratio, load, report = run(name, app, args.scenario, args, index)
            results[name].append(ratio)
            loads.append(load)
            print(f"{args.scenario}\t{name}\trun {index + 1}\t{ratio} ms/s\tload {load:.2f}", flush=True)
            if args.verbose:
                print(report, flush=True)
    print(f"\n| scenario | build | runs | median ms/s | spread (min to max) | load avg (min to max) |")
    print("| --- | --- | --- | --- | --- | --- |")
    for name, ratios in results.items():
        got = [ratio for ratio in ratios if ratio is not None]
        median = f"{statistics.median(got):.1f}" if got else "none"
        spread = f"{min(got):.1f} to {max(got):.1f}" if got else "none"
        print(
            f"| {args.scenario} | {name} | {len(got)} | {median} | {spread} | {min(loads):.2f} to {max(loads):.2f} |"
        )


if __name__ == "__main__":
    main()
