#!/usr/bin/env python3
import json, os, re, shutil, statistics, sys, time

log, edits, run = sys.argv[1], int(sys.argv[2]), sys.argv[3]
config = os.path.expanduser("~/.config/gary")
plugin = os.path.join(config, "plugins", "bench-reload")
shell = os.path.join(config, "shell.json")
commit = re.compile(r"^(\d+\.\d+) commit plugin=bench\.reload target=bar:\S+ cause=(\S+) since_ms=(\S+) .* tree=(.*)$", re.M)
fs_event = re.compile(r"^(\d+\.\d+) fs-event t0=(\d+\.\d+) paths=.*bench-reload", re.M)
manifest = {
    "schemaVersion": 1, "id": "bench.reload", "name": "Reload bench", "version": "0.1.0",
    "kinds": ["bar-widget"], "entryPoints": {"bar-widget": "widget.js"},
}
layout = {"bar": {"left": ["gary.workspaces"], "center": ["bench.reload"], "right": ["gary.battery", "gary.clock"]}}


def source(token):
    return 'module.exports = { render() { return { type: "text", text: "%s", style: "active" }; } };\n' % token


def write_in_place(path, text):
    with open(path, "w") as file:
        file.write(text)


def write_atomic(path, text):
    temporary = path + ".tmp"
    with open(temporary, "w") as file:
        file.write(text)
    os.rename(temporary, path)


def wait_for(token, after, timeout=2.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        for t, cause, since, tree in commit.findall(open(log).read()):
            if float(t) >= after and tree.startswith(token + ":"):
                return float(t), cause
        time.sleep(0.01)
    return None, None


if os.path.exists(shell) or os.path.exists(plugin):
    sys.exit(f"refusing to overwrite {shell} or {plugin}")
os.makedirs(plugin)
results = {"in-place": [], "atomic": []}
fs_lags, failures = [], 0
try:
    write_in_place(os.path.join(plugin, "manifest.json"), json.dumps(manifest))
    write_in_place(os.path.join(plugin, "widget.js"), source(f"r{run}-start"))
    write_in_place(shell, json.dumps(layout))
    if wait_for(f"r{run}-start", 0, timeout=5)[0] is None:
        sys.exit("bench plugin never committed")
    time.sleep(0.5)
    for index in range(edits):
        style = "in-place" if index % 2 == 0 else "atomic"
        token = f"r{run}-e{index}"
        written = time.time()
        (write_in_place if style == "in-place" else write_atomic)(os.path.join(plugin, "widget.js"), source(token))
        committed, cause = wait_for(token, written)
        if committed is None:
            failures += 1
            print(f"edit={index} style={style} MISSING")
            continue
        lags = [float(t0) - written for _, t0 in fs_event.findall(open(log).read()) if float(t0) >= written]
        fs_lag = min(lags) * 1000 if lags else float("nan")
        fs_lags.append(fs_lag)
        results[style].append((committed - written) * 1000)
        print(f"edit={index} style={style} write_to_commit_ms={(committed - written) * 1000:.2f} write_to_fs_event_ms={fs_lag:.2f} cause={cause}")
        time.sleep(0.4)
finally:
    os.remove(shell)
    shutil.rmtree(plugin)
every = sorted(results["in-place"] + results["atomic"])
for name, values in [("in-place", sorted(results["in-place"])), ("atomic", sorted(results["atomic"])), ("all", every)]:
    if values:
        print(f"SUMMARY run={run} style={name} n={len(values)} failures={failures} write_to_commit_ms median={statistics.median(values):.2f} "
              f"min={values[0]:.2f} max={values[-1]:.2f} over100={sum(v > 100 for v in values)}")
print(f"SUMMARY run={run} write_to_fs_event_ms median={statistics.median(fs_lags):.2f} min={min(fs_lags):.2f} max={max(fs_lags):.2f}")
