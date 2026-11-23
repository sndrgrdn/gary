import json
import re
import statistics
import sys
from pathlib import Path

MB = 1024 * 1024
root = Path(sys.argv[1])
VM_NAMES = {0: "bar", 1: "rest"}
RELIEF = [("settled", "settled"), ("settled-gc", "full GC"), ("settled-release", "+ release free memory"), ("settled-code", "+ delete JS code")]
PLUMBING = re.compile(
    r"^(libsystem_malloc\.dylib|libsystem_c\.dylib|libc\+\+\.1\.dylib|libc\+\+abi\.dylib|libobjc\.A\.dylib|libswiftCore\.dylib"
    r"|libsystem_kernel\.dylib|libsystem_blocks\.dylib|libdispatch\.dylib|CoreFoundation|Foundation|FoundationEssentials|libswiftFoundation\.dylib|probe\.dylib)$"
)
CATEGORY_GROUPS = [
    ("JavaScriptCore (WebKit Malloc, WebAssembly Memory)", ("WebKit Malloc", "WebAssembly Memory")),
    ("System malloc (all zones and metadata)", ("Malloc",)),
    ("Rendering (CoreAnimation, IOSurface, IOAccelerator, CG)", ("CoreAnimation", "IOSurface", "IOAccelerator", "CG ", "CoreGraphics", "CoreUI")),
    ("Loaded code, dirty data (__DATA, __AUTH, __OBJC, dyld)", ("__", "unused dyld shared cache area")),
    ("Untagged VM", ("Untagged",)),
    ("Thread stacks", ("Stack",)),
    ("Page table", ("page table",)),
    ("Mapped files", ("mapped file",)),
]
SWIFT_PREFIX = re.compile(r"^(closure #\d+ in |thunk for |partial apply for |specialized |merged )+")


def load(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def mb(value):
    return "–" if value is None else f"{value / MB:.1f}"


def median(numbers):
    return statistics.median(numbers) if numbers else None


def extent(numbers, offset=0):
    return f"{mb(min(numbers) - offset)}–{mb(max(numbers) - offset)}" if numbers else "–"


FAILURE = re.compile(r": failed: |stopped after running longer")


def every_run(scenario):
    directory = root / "runs" / scenario
    return sorted(path for path in directory.iterdir() if path.is_dir()) if directory.exists() else []


def log(run):
    return (run / "gary.log").read_text(errors="replace") if (run / "gary.log").exists() else ""


def runs(scenario):
    return [run for run in every_run(scenario) if not FAILURE.search(log(run))]


def phys(run, label="settled"):
    data = load(run / f"{label}.phys.json")
    return data["phys_footprint"] if data else None


def values(scenario, label="settled"):
    return [value for value in (phys(run, label) for run in runs(scenario)) if value is not None]


def health(scenario):
    loaded = {len(re.findall(r"plugin \S+/\S+: loaded", log(run))) for run in runs(scenario)}
    excluded = len(every_run(scenario)) - len(runs(scenario))
    return "/".join(str(count) for count in sorted(loaded)) or "–", excluded


def machines(run, label):
    result = {}
    for machine in (load(run / f"{label}.jsc.json") or {}).get("machines", []):
        result.setdefault(VM_NAMES.get(machine.get("index"), "transpiler"), []).append(machine)
    return result


def heap(scenario, label, vm, phase="before", field="heapSize"):
    totals = []
    for run in runs(scenario):
        found = machines(run, label).get(vm)
        if found and all(phase in machine for machine in found):
            totals.append(sum(machine[phase][field] for machine in found))
    return totals


def table(header, rows):
    lines = ["| " + " | ".join(header) + " |", "|" + "|".join("---" for _ in header) + "|"]
    return "\n".join(lines + ["| " + " | ".join(str(cell) for cell in row) + " |" for row in rows])


def zones(path):
    text = path.read_text(errors="replace") if path.exists() else ""
    scale = {"K": 1024, "M": MB, "G": 1024 * MB}
    result = {}
    for line in text.split("MALLOC ZONE", 1)[-1].splitlines():
        match = re.match(r"^(\S.*?)_0x[0-9a-f]+\s+([\d.]+[KMG])\s+([\d.]+[KMG])\s+([\d.]+[KMG])\s+([\d.]+[KMG])\s+(\d+)\s+([\d.]+[KMG])\s+([\d.]+[KMG])", line)
        if match:
            size = lambda text: float(text[:-1]) * scale[text[-1]]
            result[match.group(1)] = {"dirty": size(match.group(4)), "allocated": size(match.group(7)), "free": size(match.group(8))}
    return result


out = [f"# Gary memory ({root.name})", ""]
floor = median(values("floor"))
everything = median(values("all"))

rows = []
for scenario in ("floor", "all"):
    numbers = values(scenario)
    if numbers:
        loaded, failed = health(scenario)
        rows.append([scenario, mb(median(numbers)), extent(numbers), len(numbers), *(mb(median(values(scenario, label))) for label, _ in RELIEF[1:]), loaded, failed])
if rows:
    out += ["## Floor and all plugins (phys_footprint MB, 120 s after start)", "",
            table(["scenario", "median", "range", "runs", *(f"after {name}" for _, name in RELIEF[1:]), "slots loaded", "runs excluded for a plugin failure"], rows), ""]


def marginal_table(prefix, title, header, sign):
    entries, total = [], 0
    for directory in sorted((root / "runs").glob(f"{prefix}:*")):
        numbers = values(directory.name)
        base = floor if prefix == "plugin" else everything
        if not numbers or base is None:
            continue
        delta = sign * (median(numbers) - base)
        total += delta
        code = values(directory.name, "settled-code")
        code_base = median(values("floor" if prefix == "plugin" else "all", "settled-code"))
        code_delta = sign * (median(code) - code_base) if code and code_base is not None else None
        spread = [sign * (number - base) for number in numbers]
        loaded, failed = health(directory.name)
        bar_heap, rest_heap = median(heap(directory.name, "settled", "bar")), median(heap(directory.name, "settled", "rest"))
        row = [directory.name.split(":", 1)[1], mb(delta), f"{mb(min(spread))}–{mb(max(spread))}", len(numbers), mb(code_delta), mb(bar_heap), mb(rest_heap), loaded, failed]
        if prefix == "plugin":
            shape = {(True, True): "both", (True, False): "effect-widget", (False, True): "effect-service"}.get(
                ((bar_heap or 0) > MB, (rest_heap or 0) > MB), "plain-widget" if loaded not in ("0", "–") else None)
            reference = median(values(f"effect:{shape}")) if shape else floor
            row.insert(2, f"{mb(median(numbers) - reference)} over {shape or 'floor'}" if reference is not None else "–")
        entries.append((delta, row))
    if entries:
        out.extend([f"## {title}", "", table(header, [row for _, row in sorted(entries, key=lambda item: -item[0])]), ""])
    return total if entries else None


header = ["plugin", "MB", "range", "runs", "MB after GC, release, code delete", "bar VM JS heap", "rest VM JS heap", "slots loaded", "runs excluded for a plugin failure"]
alone = marginal_table("plugin", "Per plugin alone on an empty bar (median minus floor median)", header[:2] + ["own cost over a minimal plugin of the same shape"] + header[2:], 1)
if alone is not None and everything is not None and floor is not None:
    out += [f"Sum of alone marginals {mb(alone)} MB; all plugins together minus floor {mb(everything - floor)} MB.", ""]
without = marginal_table("without", "Per plugin left out of the full config (all median minus without-plugin median)", header, -1)
if without is not None and everything is not None and floor is not None:
    out += [f"Sum of leave-one-out savings {mb(without)} MB; all plugins together minus floor {mb(everything - floor)} MB.", ""]

effect = {name: values(f"effect:{name}") for name in ("plain-widget", "effect-widget", "plain-service", "effect-service", "both")}
if all(effect.values()) and floor is not None:
    rows = [[name, mb(median(numbers)), extent(numbers), len(numbers), mb(median(values(f"effect:{name}", "settled-code")))] for name, numbers in effect.items()]
    medians = {name: median(numbers) for name, numbers in effect.items()}
    first_bar = medians["effect-widget"] - medians["plain-widget"]
    first_rest = medians["effect-service"] - medians["plain-service"]
    second = medians["both"] - medians["effect-widget"] - (medians["plain-service"] - floor)
    out += ["## gary:effect load cost (MB)", "", table(["scenario", "median", "range", "runs", "after GC, release, code delete"], rows), "",
            f"- First load, bar VM (effect widget minus plain widget): {mb(first_bar)} MB.",
            f"- First load, rest VM (effect service minus plain service): {mb(first_rest)} MB.",
            f"- Second copy, rest VM while the bar VM already holds one (both minus effect widget minus a plain service's cost): {mb(second)} MB.",
            f"- A plain widget with no gary:effect over the floor: {mb(medians['plain-widget'] - floor)} MB.", ""]

deep_runs = [run for run in runs("all") if (run / "settled.footprint.json").exists()]
if deep_runs:
    grouped = {}
    for run in deep_runs:
        sums = {}
        for name, entry in load(run / "settled.footprint.json")["processes"][0]["categories"].items():
            group = next((label for label, prefixes in CATEGORY_GROUPS if any(name.startswith(prefix) for prefix in prefixes)), "Other")
            sums[group] = sums.get(group, 0) + entry["dirty"] + entry.get("swapped", 0)
        for group, size in sums.items():
            grouped.setdefault(group, []).append(size)
    rows = [[group, mb(median(sizes)), extent(sizes)] for group, sizes in sorted(grouped.items(), key=lambda item: -median(item[1]))]
    out += ["## Split of the all-plugins footprint by VM region (dirty + swapped MB)", "", table(["region group", "median", "range"], rows), ""]
    rows = []
    for label in ("settled", "settled-code"):
        found = [zones(run / f"{label}.vmmap.txt") for run in deep_runs]
        for zone in ("WebKit Malloc", "DefaultMallocZone"):
            entries = [each[zone] for each in found if zone in each]
            if entries:
                rows.append([label, zone, *(mb(median([entry[key] for entry in entries])) for key in ("dirty", "allocated", "free"))])
    out += ["### Malloc zones: live allocations versus dirty pages (vmmap, median MB)", "",
            table(["point", "zone", "dirty", "allocated (live)", "free inside dirty pages"], rows), ""]
    rows = []
    for vm in ("bar", "rest", "transpiler"):
        size, capacity, extra = (median(heap("all", "settled", vm, "before", field)) for field in ("heapSize", "heapCapacity", "extraMemorySize"))
        if size is not None:
            rows.append([vm, mb(size), mb(capacity), mb(extra), mb(median(heap("all", "settled-gc", vm, "after"))), mb(median(heap("all", "settled-code", vm, "after")))])
    out += ["### JavaScriptCore heap per VM (median of all-plugins runs, MB)", "",
            table(["VM", "heap size", "heap capacity", "extra memory", "heap after full GC", "heap after code delete + GC"], rows), ""]

growth = runs("growth")
if growth:
    run = growth[0]
    labels = ["settled"] + sorted({path.name.split(".")[0] for path in run.glob("cycles*.phys.json") if "-" not in path.name.split(".")[0]},
                                  key=lambda name: int(name[6:]))
    last = labels[-1]
    rows = []
    for label in labels + [f"{last}-gc", f"{last}-release", f"{last}-code"]:
        value = phys(run, label)
        if value is None:
            continue
        vms = machines(run, label)
        phase = "after" if label.endswith(("-gc", "-release", "-code")) else "before"
        heaps = [mb(sum(machine[phase]["heapSize"] for machine in vms[vm])) if vms.get(vm) and all(phase in each for each in vms[vm]) else "–"
                 for vm in ("bar", "rest", "transpiler")]
        rows.append([label, mb(value), *heaps])
    out += ["## Growth: launcher and audio menu opened and closed (one run, 120 s settle before each point)", "",
            table(["point", "phys_footprint", "bar VM JS heap", "rest VM JS heap", "transpiler VM JS heap"], rows), ""]


def attribute(path):
    totals, callers, stack = {}, {}, []
    pattern = re.compile(r"^([ +!:|]*)(\d+) \(([\d.]+) ?(bytes|K|M|G)\) (.*?)  \(in ([^)]+)\)")
    scale = {"bytes": 1, "K": 1024, "M": MB, "G": 1024 * MB}

    def close(entry):
        own = entry["size"] - entry["children"]
        if entry["state"] == "plumbing" and own > 0:
            key = f"(allocator) {entry['library']}"
            totals[key] = totals.get(key, 0) + own

    def charge(owner, symbol, size):
        key = (owner, SWIFT_PREFIX.sub("", symbol))
        callers[key] = callers.get(key, 0) + size

    with open(path, errors="replace") as handle:
        for line in handle:
            match = pattern.match(line)
            if not match:
                continue
            depth, size = len(match.group(1)), float(match.group(3)) * scale[match.group(4)]
            symbol, library = match.group(5), match.group(6)
            while stack and stack[-1]["depth"] >= depth:
                close(stack.pop())
            parent = stack[-1] if stack else None
            if parent:
                parent["children"] += size
            state, owner = "done", None
            if parent is None or parent["state"] == "plumbing":
                if PLUMBING.match(library):
                    state = "plumbing"
                else:
                    state, owner = "owned", library
                    totals[library] = totals.get(library, 0) + size
                    if library == "gary":
                        charge(library, symbol, size)
                        state = "done"
            elif parent["state"] == "owned":
                state, owner = "owned", parent["owner"]
                if library == "gary":
                    charge(owner, symbol, size)
                    state = "done"
            stack.append({"depth": depth, "size": size, "children": 0, "library": library, "state": state, "owner": owner})
    while stack:
        close(stack.pop())
    return totals, callers


attribution = runs("attribution")
if attribution and (attribution[0] / "settled.calltree.txt").exists():
    run = attribution[0]
    totals, callers = attribute(run / "settled.calltree.txt")
    total = sum(totals.values())
    rows = [[library, mb(size), f"{100 * size / total:.0f}%"] for library, size in sorted(totals.items(), key=lambda item: -item[1])[:20]]
    out += ["## Live malloc by responsible library (one MallocStackLogging=lite run; JSC uses system malloc in this mode)", "",
            f"Live malloc with stacks {mb(total)} MB; phys_footprint of this run {mb(phys(run))} MB, inflated by stack logging.", "",
            table(["first non-allocator library", "MB", "share"], rows), ""]
    for owner in ("JavaScriptCore", "gary", "SwiftUICore", "AppKit"):
        owned = sorted(((name, size) for (library, name), size in callers.items() if library == owner), key=lambda item: -item[1])[:10]
        if owned:
            out += [f"### {owner} allocations by the first Gary frame below them", "",
                    table(["Gary frame", "MB"], [[name[:110].replace("|", "/"), mb(size)] for name, size in owned]), ""]

print("\n".join(out))
