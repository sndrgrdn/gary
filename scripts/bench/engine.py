#!/usr/bin/env python3
import json, statistics, sys

runs = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]


def spread(values, digits=2):
    return f"{statistics.median(values):.{digits}f} ({min(values):.{digits}f} to {max(values):.{digits}f})"


print("| Side | Runs | Widget wait p50, ms | p95, ms | max, ms | Plugin memory, MB | False kills | Runaway stopped after, ms | Others kept running | Load |")
print("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
for side in dict.fromkeys(run["side"] for run in runs):
    group = [run for run in runs if run["side"] == side]
    widgets = [run["widgets"] for run in group]
    runaway = [run["runaway"] for run in group]
    stopped = sum(1 for each in runaway if each["stopped"])
    print(f"| {side} | {len(group)} | {spread([w['p50'] for w in widgets])} | {spread([w['p95'] for w in widgets])} | {spread([w['max'] for w in widgets])} "
          f"| {spread([run['memoryMB']['p50'] for run in group], 1)} | {sum(run['falseKills'] for run in group)} "
          f"| {stopped}/{len(group)}, {spread([each['afterMs'] for each in runaway], 0)} | {sum(1 for each in runaway if each['othersRunning'])}/{len(group)} "
          f"| {spread([run['load1'] for run in group], 1)} |")
print()
for run in runs:
    samples = int(run["widgets"]["n"])
    per = ", ".join(f"{name} p95 {stats['p95']:.2f}" for name, stats in sorted(run["perWidget"].items()))
    outputs = ", ".join(f"{name} {count / run['seconds']:.1f}/s" for name, count in sorted(run["outputs"].items()))
    loads = ", ".join(f"{name} {ms:.1f}" for name, ms in sorted(run.get("loadMs", {}).items()))
    print(f"{run['side']}: {samples} widget samples; {per}; outputs {outputs}; load ms {loads}; failures {run['failures'] or 'none'}")

for run in runs:
    profile = dict(run.get("profile", {}))
    if not profile:
        continue
    frames = profile.pop("busyFrames")
    print(f"{run['side']} profile: engine held {profile.pop('busyFraction') * 100:.1f}% of the time; busy frame in the lock p50 {frames['inLock']['p50']:.2f} ms, "
          + ", ".join(f"{stage} {frames[stage]['p50']:.2f}" for stage in ("js_parse", "render", "stringify", "handler") if stage in frames))
    for plugin, each in sorted(profile.items()):
        behind = ", ".join(f"{who} {ms:.0f}" for who, ms in sorted(each["waitBehindMs"].items(), key=lambda item: -item[1]) if ms >= 1)
        print(f"  {plugin}: held p50 {each['hold']['p50']:.2f}, p95 {each['hold']['p95']:.2f}, max {each['hold']['max']:.2f}, total {each['holdTotalMs']:.0f} ms; "
              f"waited p95 {each['wait']['p95']:.2f}, max {each['wait']['max']:.2f} ms, behind {behind or 'nobody'}")
