#!/usr/bin/env python3
import ctypes, json, os, re, shutil, statistics, subprocess, sys, threading, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
APP = os.path.abspath(os.environ.get("BENCH_APP", os.path.join(ROOT, "build", "Gary.app")))
GARY = os.path.join(APP, "Contents", "MacOS", "gary")
METER = os.path.join(ROOT, "tmp", "bin", "meter")
WINDOWS = os.path.join(ROOT, "tmp", "bin", "windows")
PLUGINS = os.path.join(ROOT, "scripts", "bench", "plugins")
WORK = os.path.join(ROOT, "tmp", "bench")
CONFIG = os.path.expanduser("~/.config/gary")
SHELL = os.path.join(CONFIG, "shell.json")
BACKUP = os.path.join(WORK, "shell.json.bak")
USER_APP = os.path.expanduser("~/Applications/Gary.app")
SETTLE = 20
WARM = 3


def busy(nodes, hz=30):
    return {"plugins": ["bench.busy"], "settings": {"bench.busy": {"nodes": nodes, "hz": hz}}, "summon": "bench.busy", "stats": "bench.busy",
            "warm": 5}


def loops(mode):
    return {"plugins": ["bench.loops"], "settings": {"bench.loops": {"mode": mode}}, "summon": "bench.loops", "stats": "bench.loops"}


def feed(bytes):
    return {"bar": ["bench.sink"], "plugins": ["bench.feed"], "start": ["bench.feed", "start", str(bytes)], "stats": "bench.sink"}


CASES = {
    "s1-idle": {"bar": ["bench.tick"], "stats": "bench.tick", "seconds": 60, "repaint": 1.1},
    "s2-busy-100": busy(100),
    "s2-busy-500": busy(500),
    "s2-busy-1000": busy(1000),
    "s3-first-1000": {**busy(1000, hz=0), "summon": None, "first": "bench.busy"},
    "s6-launch-1000": {**busy(1000), "settle": 0, "warm": 0},
    "s4-static": loops("static"),
    "s4-loops": loops("loops"),
    "s4-shader": loops("shader"),
    "s5-small": feed(1_000),
    "s5-large": feed(200_000),
}
DARK_OK = {"s1-idle", "s2-busy-100", "s5-large", "s6-launch-1000"}
STAGES = ["evaluate", "encode", "js_parse", "handler", "render", "stringify", "swift_parse", "node_parse", "compare", "apply", "layout",
          "display", "flush"]
LINE = re.compile(r"^(\d+\.\d+) (commit|render) plugin=(\S+?)(?:/\S+)? (.*)$")
FIELD = re.compile(r"(\w+)_ms=([\d.]+)")


def cli(*arguments, timeout=10):
    return subprocess.run([GARY, *arguments], capture_output=True, text=True, timeout=timeout)


def pids(pattern):
    found = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True).stdout.split()
    return [int(pid) for pid in found]


def wait_for(check, timeout, step=0.1):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = check()
        if value:
            return value
        time.sleep(step)
    return None


def quit_all():
    cli("quit", timeout=15)
    if not wait_for(lambda: not pids("Gary.app/Contents/MacOS/gary"), 10):
        subprocess.run(["pkill", "-f", "Gary.app/Contents/MacOS/gary"])
        wait_for(lambda: not pids("Gary.app/Contents/MacOS/gary"), 5)


def clean():
    for name in os.listdir(os.path.join(CONFIG, "plugins")):
        if os.path.exists(os.path.join(CONFIG, "plugins", name, ".bench")):
            shutil.rmtree(os.path.join(CONFIG, "plugins", name))
    if os.path.exists(BACKUP):
        shutil.copyfile(BACKUP, SHELL)
        os.remove(BACKUP)


def restore():
    quit_all()
    clean()
    subprocess.run(["open", "-g", "-a", USER_APP])
    wait_for(lambda: subprocess.run(["gary", "ping"], capture_output=True).returncode == 0, 15)


def install(case):
    clean()
    os.makedirs(WORK, exist_ok=True)
    shutil.copyfile(SHELL, BACKUP)
    shell = json.load(open(SHELL))
    for id in sorted(set(case.get("bar", []) + case.get("plugins", []) + [case.get("summon") or case.get("first")]) - {None}):
        target = os.path.join(CONFIG, "plugins", id)
        shutil.copytree(os.path.join(PLUGINS, id), target)
        open(os.path.join(target, ".bench"), "w").close()
    shell.setdefault("bar", {}).setdefault("right", [])
    shell["bar"]["right"] = case.get("bar", []) + shell["bar"]["right"]
    shell["plugins"] = shell.get("plugins", []) + case.get("plugins", [])
    shell.setdefault("settings", {}).update(case.get("settings", {}))
    with open(SHELL, "w") as file:
        json.dump(shell, file, indent=2)


def launch(log, trace):
    quit_all()
    command = ["open", "-g", "--stdout", log, "--stderr", log]
    if trace:
        command += ["--env", "GARY_TRACE=1"]
    subprocess.run(command + [APP], check=True)
    pid = wait_for(lambda: pids(f"{APP}/Contents/MacOS/gary app$"), 15)
    if not pid or not wait_for(lambda: cli("ping").returncode == 0, 15):
        raise RuntimeError("bench Gary did not start")
    return pid[0]


def stats(id):
    result = cli("call", id, "stats")
    return json.loads(result.stdout) if result.returncode == 0 else {"error": result.stderr.strip()}


def settle(id, fast=0.1, streak=3, timeout=90):
    started, quick = time.time(), 0
    while quick < streak and time.time() - started < timeout:
        called = time.time()
        stats(id)
        quick = quick + 1 if time.time() - called < fast else 0
        time.sleep(0.5)
    return {"settle_s": time.time() - started, "settled": quick >= streak}


def cpu_seconds(pid):
    text = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    minutes, seconds = text.split(":") if text else ("0", "0")
    return int(minutes) * 60 + float(seconds)


def gpu_percent():
    text = subprocess.run(["ioreg", "-r", "-d", "1", "-c", "IOAccelerator"], capture_output=True, text=True).stdout
    found = re.search(r'"Device Utilization %"=(\d+)', text)
    return int(found.group(1)) if found else None


def screen():
    graphics = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    graphics.CGMainDisplayID.restype = ctypes.c_uint32
    graphics.CGDisplayIsAsleep.argtypes = [ctypes.c_uint32]
    graphics.CGDisplayIsAsleep.restype = ctypes.c_bool
    if graphics.CGDisplayIsAsleep(graphics.CGMainDisplayID()):
        return "asleep"
    root = subprocess.run(["ioreg", "-n", "Root", "-d1"], capture_output=True, text=True).stdout
    return "locked" if '"CGSSessionScreenIsLocked"=Yes' in root else "on"


def noise():
    load = subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout.strip("{} \n").split()[0]
    top = subprocess.run(["ps", "-Ao", "pcpu=,comm="], capture_output=True, text=True).stdout.splitlines()
    busiest = sorted((line.split(None, 1) for line in top if line.strip()), key=lambda row: -float(row[0]))[:4]
    return {"load1": float(load), "top": [f"{float(cpu):.0f}% {os.path.basename(name.strip())}" for cpu, name in busiest], "screen": screen()}


def measure(pid, seconds):
    server = pids("WindowServer")
    gpu = []
    done = threading.Event()

    def sample():
        while not done.wait(1):
            gpu.append(gpu_percent())

    sampler = threading.Thread(target=sample)
    server_start = cpu_seconds(server[0]) if server else None
    sampler.start()
    output = subprocess.run([METER, str(seconds), f"gary={pid}"], capture_output=True, text=True).stdout
    done.set()
    sampler.join()
    fields = dict(re.findall(r"(\w+)=([\d.]+)", output))
    gpu = [value for value in gpu if value is not None]
    return {
        "cpu_pct": float(fields["cpu_pct"]),
        "wakeups_per_s": float(fields["wakeups_per_s"]),
        "minstructions_per_s": float(fields["minstructions_per_s"]),
        "mcycles_per_s": float(fields["mcycles_per_s"]),
        "pcycles_pct": float(fields["pcycles_pct"]),
        "energy_mw": float(fields["energy_mw"]),
        "footprint_mb": float(fields["footprint_end_mb"]),
        "windowserver_cpu_pct": (cpu_seconds(server[0]) - server_start) / seconds * 100 if server else None,
        "gpu_pct": statistics.mean(gpu) if gpu else None,
    }


def repainted(pid, wait):
    rows = subprocess.run([WINDOWS, str(pid)], capture_output=True, text=True).stdout.splitlines()
    windows = [dict(re.findall(r"(\w+)=(\S+)", row)) for row in rows]
    shown = [window for window in windows if window["onscreen"] == "true"]
    if not shown:
        return None
    largest = max(shown, key=lambda window: int(window["frame"].split(",")[2]) * int(window["frame"].split(",")[3]))
    shots = []
    for index in range(2):
        path = os.path.join(WORK, f"repaint-{index}.png")
        subprocess.run(["screencapture", "-x", "-o", "-l", largest["id"], path])
        shots.append(open(path, "rb").read())
        time.sleep(wait)
    return {"window": largest["frame"], "changed": shots[0] != shots[1]}


def traced(log, id, start, end):
    commits, unchanged, plugins = [], 0, {}
    for line in open(log, errors="replace"):
        found = LINE.match(line)
        if not found or not start <= float(found.group(1)) <= end:
            continue
        counts = plugins.setdefault(found.group(3), {"commit": 0, "render": 0})
        counts[found.group(2)] += 1
        if found.group(3) != id:
            continue
        if found.group(2) == "render":
            unchanged += 1
            continue
        head = found.group(4).split(" tree=", 1)[0]
        values = {name: float(value) for name, value in FIELD.findall(head)}
        values["cause"] = re.search(r"cause=(\S+)", head).group(1)
        values["changed"] = int(re.search(r"changed=(\d)", head).group(1))
        commits.append(values)
    return commits, unchanged, plugins


def transient(log, id, end, slow=100):
    commits, _, _ = traced(log, id, 0, end)
    if not commits:
        return None
    times = [float(line.split(" ", 1)[0]) for line in open(log, errors="replace") if LINE.match(line) and f" commit plugin={id}" in line]
    late = [index for index, commit in enumerate(commits) if commit["since"] > slow]
    return {"peak_since_ms": max(commit["since"] for commit in commits),
            "slow_until_s": times[late[-1]] - times[0] if late and len(times) == len(commits) else 0}


def percentiles(commits):
    summary = {}
    for name in ["since"] + STAGES:
        values = sorted(commit[name] for commit in commits if name in commit)
        if values:
            summary[name] = {"p50": values[len(values) // 2], "p95": values[min(len(values) - 1, int(len(values) * 0.95))]}
    return summary


def first_render(case, log, trace):
    id = case["first"]
    runs = []
    for attempt in range(4):
        started = time.time()
        result = cli("summon", id)
        wall = (time.time() - started) * 1000
        commits = traced(log, id, started, time.time() + 1)[0] if trace else []
        first = next((commit for commit in commits if commit["cause"] == "ipc-summon"), None)
        runs.append({"cold": attempt == 0, "ok": result.returncode == 0 and result.stdout.strip() == "shown", "cli_ms": wall,
                     "commit": first})
        time.sleep(1)
        cli("hide", id)
        time.sleep(1)
    return {"summons": runs, "stats": stats(id)}


def run(name, out, trace, dark_ok=False):
    case = CASES[name]
    log = os.path.join(WORK, f"{name}-{int(time.time())}.log")
    result = {"case": name, "trace": trace, "app": os.path.relpath(APP, ROOT), "time": time.time()}
    if dark_ok:
        result["dark_ok"] = True
    state = screen()
    if state != "on" and not (dark_ok and name in DARK_OK):
        result["error"] = f"screen is {state}, so windows are not composited"
        with open(out, "a") as file:
            file.write(json.dumps(result) + "\n")
        print(json.dumps(result))
        return
    try:
        install(case)
        pid = launch(log, trace)
        time.sleep(case.get("settle", SETTLE))
        if case.get("start"):
            result["started"] = cli("call", *case["start"]).stdout.strip()
        if case.get("summon"):
            result["summon"] = cli("summon", case["summon"]).stdout.strip()
        time.sleep(case.get("warm", WARM))
        if case.get("stats"):
            result.update(settle(case["stats"]))
        result["noise_before"] = noise()
        if case.get("first"):
            result.update(first_render(case, log, trace))
        else:
            seconds = case.get("seconds", 15)
            before = stats(case["stats"])
            start = time.time()
            result.update(measure(pid, seconds))
            end = time.time()
            after = stats(case["stats"])
            result["stats_before"], result["stats_after"] = before, after
            result["repainted"] = repainted(pid, case.get("repaint", 0.5))
            result["window_s"] = end - start
            if trace:
                commits, unchanged, plugins = traced(log, case["stats"], start, end)
                result["plugins"] = plugins
                subprocess.run(["screencapture", "-x", log.replace(".log", ".png")])
                result["commits"] = len(commits)
                result["commits_changed"] = sum(commit["changed"] for commit in commits)
                result["unchanged_renders"] = unchanged
                result["stages"] = percentiles(commits)
                result["since_first_last"] = [commits[0]["since"], commits[-1]["since"]] if commits else None
                result["transient"] = transient(log, case["stats"], end)
        result["noise_after"] = noise()
        result["failed_lines"] = [line.strip() for line in open(log, errors="replace") if "failed" in line or "stopped after" in line]
    except Exception as error:
        result["error"] = repr(error)
    finally:
        restore()
    result["log"] = log
    with open(out, "a") as file:
        file.write(json.dumps(result) + "\n")
    print(json.dumps({key: result.get(key) for key in ["case", "trace", "cpu_pct", "commits", "error"]}))


def profile(name, seconds, out, dark_ok=False):
    case = CASES[name]
    if screen() != "on" and not (dark_ok and name in DARK_OK):
        sys.exit(f"screen is {screen()}, so windows are not composited")
    log = os.path.join(WORK, f"profile-{name}-{int(time.time())}.log")
    try:
        install(case)
        pid = launch(log, False)
        time.sleep(SETTLE)
        if case.get("start"):
            cli("call", *case["start"])
        if case.get("summon"):
            cli("summon", case["summon"])
        time.sleep(case.get("warm", WARM))
        if case.get("first"):
            sampler = subprocess.Popen(["sample", str(pid), str(seconds), "5", "-file", out], stdout=subprocess.DEVNULL)
            time.sleep(0.5)
            for _ in range(int(seconds / 2)):
                cli("summon", case["first"])
                time.sleep(0.5)
                cli("hide", case["first"])
                time.sleep(0.5)
            sampler.wait()
        else:
            subprocess.run(["sample", str(pid), str(seconds), "5", "-file", out], stdout=subprocess.DEVNULL)
    finally:
        restore()
    print(out)


def report(path):
    rows = [json.loads(line) for line in open(path)]
    by_case = {}
    for row in rows:
        by_case.setdefault((row["case"], row["trace"], row.get("app", "build/Gary.app"), row.get("dark_ok", False)), []).append(row)

    def spread(values, unit="", digits=1):
        values = [value for value in values if value is not None]
        if not values:
            return "n/a"
        return f"{statistics.median(values):.{digits}f}{unit} ({min(values):.{digits}f} to {max(values):.{digits}f}, n={len(values)})"

    def rate(run, counter):
        before, after = run["stats_before"], run["stats_after"]
        seconds = (after["at"] - before["at"]) / 1000 if "at" in before and "at" in after else run["window_s"]
        return (after.get(counter, 0) - before.get(counter, 0)) / seconds

    for (name, trace, app, dark_ok), runs in sorted(by_case.items()):
        errors = [run["error"] for run in runs if "error" in run]
        runs = [run for run in runs if "error" not in run]
        screens = {run["noise_before"].get("screen") for run in runs} | {run["noise_after"].get("screen") for run in runs}
        dark = [run for run in runs if run["noise_before"].get("screen") != run["noise_after"].get("screen")
                or not dark_ok and run["noise_before"].get("screen") != "on"]
        runs = [run for run in runs if run not in dark]
        print(f"## {name} {'traced' if trace else 'untraced'} {app}{' screen ' + '/'.join(sorted(screens - {None})) if dark_ok else ''}")
        if errors:
            print(f"errors: {len(errors)}, first: {errors[0]}")
        if dark:
            print(f"excluded {len(dark)} runs taken while the screen was locked or asleep, or changed state")
        if not runs:
            continue
        loads = [run["noise_before"]["load1"] for run in runs] + [run["noise_after"]["load1"] for run in runs]
        print(f"load1 {min(loads):.2f} to {max(loads):.2f}; failed lines: {sum(len(run['failed_lines']) for run in runs)}; "
              f"settled {sum(run.get('settled', True) for run in runs)}/{len(runs)}, settle {spread([run.get('settle_s') for run in runs], ' s')}")
        if name.startswith("s3"):
            cold = [summon for run in runs for summon in run["summons"] if summon["cold"]]
            warm = [summon for run in runs for summon in run["summons"] if not summon["cold"]]
            for label, group in [("cold", cold), ("repeat", warm)]:
                print(f"{label}: ok {sum(summon['ok'] for summon in group)}/{len(group)}, "
                      f"summon to first commit (cli round trip) {spread([summon['cli_ms'] for summon in group], ' ms')}")
                commits = [summon["commit"] for summon in group if summon["commit"]]
                if commits:
                    print(f"  " + "; ".join(f"{stage} {spread([commit.get(stage) for commit in commits], ' ms', 2)}"
                                            for stage in ["since"] + STAGES if any(stage in commit for commit in commits)))
            continue
        counter = "frames" if name.startswith(("s2", "s5")) else "renders" if name.startswith("s4") else "ticks"
        produced = [rate(run, counter) for run in runs]
        renders = [rate(run, "renders") for run in runs]
        print(f"gary cpu {spread([run['cpu_pct'] for run in runs], '%')}; wakeups/s {spread([run['wakeups_per_s'] for run in runs])}")
        if all("energy_mw" in run for run in runs):
            print(f"instructions {spread([run['minstructions_per_s'] for run in runs], ' M/s', 0)}; "
                  f"cycles {spread([run['mcycles_per_s'] for run in runs], ' M/s', 0)}; "
                  f"p-core cycles {spread([run['pcycles_pct'] for run in runs], '%')}; energy {spread([run['energy_mw'] for run in runs], ' mW')}")
        print(f"windowserver cpu {spread([run['windowserver_cpu_pct'] for run in runs], '%')}; gpu {spread([run['gpu_pct'] for run in runs], '%')}")
        print(f"footprint {spread([run['footprint_mb'] for run in runs], ' MB')}; {counter}/s {spread(produced)}; js renders/s {spread(renders)}")
        if trace:
            print(f"commits/s {spread([run['commits'] / run['window_s'] for run in runs])}; "
                  f"unchanged renders/s {spread([run['unchanged_renders'] / run['window_s'] for run in runs])}")
            for stage in ["since"] + STAGES:
                p50 = [run["stages"][stage]["p50"] for run in runs if stage in run["stages"]]
                p95 = [run["stages"][stage]["p95"] for run in runs if stage in run["stages"]]
                if p50:
                    print(f"  {stage}: p50 {spread(p50, ' ms', 3)}; p95 {spread(p95, ' ms', 3)}")
        print()


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "run" and len(sys.argv) >= 4 and sys.argv[2] in CASES:
        run(sys.argv[2], sys.argv[3], "--trace" in sys.argv, "--dark-ok" in sys.argv)
    elif command == "profile" and len(sys.argv) >= 5 and sys.argv[2] in CASES:
        profile(sys.argv[2], int(sys.argv[3]), sys.argv[4], "--dark-ok" in sys.argv)
    elif command == "report" and len(sys.argv) == 3:
        report(sys.argv[2])
    elif command == "restore":
        restore()
    else:
        sys.exit(f"usage: render.py run <case> <out.jsonl> [--trace] [--dark-ok] | profile <case> <seconds> <out.txt> [--dark-ok] | report <out.jsonl> | restore\n"
                 f"cases: {', '.join(CASES)}")
