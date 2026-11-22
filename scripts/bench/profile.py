#!/usr/bin/env python3
import re, sys

IDLE = re.compile(r"^(start_wqthread|thread_start|mach_msg2_trap|__psynch_cvwait|__workq_kernreturn|semaphore_wait_trap|semaphore_timedwait_trap|__semwait_signal|kevent\w*|__ulock_wait2?|__select)\b")
LINE = re.compile(r"^([\s+!:|]*)(\d+) (.+?)(?:  \(in ([^)]+)\).*)?$")


class Frame:
    def __init__(self, name, library, count):
        self.name, self.library, self.count, self.children = name, library, count, []

    def idle(self):
        own = self.count - sum(child.count for child in self.children)
        return (own if IDLE.match(self.name) else 0) + sum(child.idle() for child in self.children)

    def busy(self):
        return self.count - self.idle()


def threads(path):
    roots, stack = [], []
    lines = open(path, errors="replace").read().split("Call graph:\n", 1)[1].split("\n\nTotal number in stack", 1)[0].splitlines()
    for line in lines:
        found = LINE.match(line)
        if not found:
            continue
        depth = len(found.group(1))
        frame = Frame(found.group(3).strip(), found.group(4) or "", int(found.group(2)))
        while stack and stack[-1][0] >= depth:
            stack.pop()
        if stack:
            stack[-1][1].children.append(frame)
        else:
            roots.append(frame)
        stack.append((depth, frame))
    return roots


def short(name):
    name = re.sub(r"\s*\[0x[0-9a-f]+\]$", "", name)
    name = re.sub(r"\s*\+ \d+$", "", name)
    return name if len(name) <= 110 else name[:107] + "..."


def show(frame, total, floor, depth=0, out=None):
    busy = frame.busy()
    if busy < floor:
        return
    children = [child for child in frame.children if child.busy() >= floor]
    if len(children) == 1 and children[0].busy() >= busy * 0.97 and depth > 0:
        show(children[0], total, floor, depth, out)
        return
    out.append(f"{'  ' * depth}{busy * 100 / total:5.1f}%  {short(frame.name)}  ({frame.library})")
    for child in sorted(children, key=lambda child: -child.busy()):
        show(child, total, floor, depth + 1, out)


def self_time(frame, totals):
    own = frame.count - sum(child.count for child in frame.children)
    if own and not IDLE.match(frame.name):
        key = f"{short(frame.name)}  ({frame.library})"
        totals[key] = totals.get(key, 0) + own
    for child in frame.children:
        self_time(child, totals)


def main(path, share=3.0):
    roots = threads(path)
    duration = max(root.count for root in roots)
    print(f"# {path}\nsamples per thread at most {duration}")
    busy = sum(root.busy() for root in roots)
    print(f"all threads: busy {busy * 100 / duration:.1f}% of one core")
    totals = {}
    for root in roots:
        self_time(root, totals)
    for key, count in sorted(totals.items(), key=lambda item: -item[1])[:8]:
        print(f"  {count * 100 / busy:5.1f}%  {key}")
    print()
    for root in sorted(roots, key=lambda root: -root.busy()):
        busy = root.busy()
        if busy < duration * 0.02:
            continue
        print(f"## {short(root.name)}: busy {busy} of {root.count} samples ({busy * 100 / duration:.1f}% of one core)")
        out = []
        for child in root.children:
            show(child, busy, busy * share / 100, 0, out)
        print("\n".join(out[:60]))
        totals = {}
        self_time(root, totals)
        print("top self time:")
        for key, count in sorted(totals.items(), key=lambda item: -item[1])[:12]:
            print(f"  {count * 100 / busy:5.1f}%  {key}")
        print()


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit("usage: profile.py <sample.txt> [min share %]")
    main(sys.argv[1], float(sys.argv[2]) if len(sys.argv) == 3 else 3.0)
