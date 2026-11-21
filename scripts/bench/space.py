#!/usr/bin/env python3
import re, statistics, subprocess, sys, time

log, switches, run = sys.argv[1], int(sys.argv[2]), sys.argv[3]
event = re.compile(r"space-event src=(\S+) t0=(\d+\.\d+)")
commit = re.compile(r"^(\d+\.\d+) commit plugin=gary\.workspaces target=bar:\S+ cause=(\S+) .* tree=(.*)$", re.M)


def dinky(*args):
    return subprocess.run(["dinky", *args], capture_output=True, text=True).stdout.strip()


def active(tree):
    names = [token.rsplit(":", 1)[0] for token in tree.split() if token.endswith(":active")]
    return names[0] if names else None


start = dinky("list-workspaces", "--focused").splitlines()[0]
others = [name for name in dinky("list-workspaces", "--all").split() if name != start][:2]
latencies, totals, missing, stale_total = [], [], 0, 0
try:
    for index in range(switches):
        target = others[(index // 2) % len(others)] if index % 2 == 0 else start
        sent = time.time()
        dinky("workspace", target)
        time.sleep(1.2)
        text = open(log).read()
        events = sorted((float(t), source) for source, t in event.findall(text) if float(t) >= sent)
        commits = [(float(t), cause, active(tree)) for t, cause, tree in commit.findall(text) if float(t) >= sent]
        good = [c for c in commits if c[2] == target]
        if not events or not good:
            missing += 1
            print(f"switch={index} target={target} events={events[:2]} commits={commits[:2]} MISSING")
            continue
        first_event, source = events[0]
        stale = [c for c in commits if c[0] < good[0][0]]
        stale_total += len(stale)
        latency = (good[0][0] - first_event) * 1000
        latencies.append(latency)
        totals.append((good[0][0] - sent) * 1000)
        print(f"switch={index} target={target} first_event={source} event_to_commit_ms={latency:.2f} "
              f"sent_to_event_ms={(first_event - sent) * 1000:.1f} sent_to_commit_ms={(good[0][0] - sent) * 1000:.1f} "
              f"commit_cause={good[0][1]} stale_commits={len(stale)} events={[s for _, s in events]}")
finally:
    dinky("workspace", start)
    time.sleep(0.5)
    print(f"restored workspace {start}, focused now {dinky('list-workspaces', '--focused').splitlines()[0]}")
if latencies:
    ordered = sorted(latencies)
    print(f"SUMMARY run={run} n={len(latencies)}/{switches} missing={missing} stale={stale_total} "
          f"event_to_commit_ms median={statistics.median(ordered):.2f} min={ordered[0]:.2f} max={ordered[-1]:.2f} over50={sum(l > 50 for l in ordered)} "
          f"| sent_to_commit_ms median={statistics.median(totals):.1f} min={min(totals):.1f} max={max(totals):.1f}")
