#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage="usage: scripts/memory.sh [floor | all | plugins | plugin:<id> | without | without:<id> | effect | growth | attribution | timeline] ...
Runs a private Gary from \$APP (default build/Gary.app) per scenario, each with its own home, config, lock, and socket,
with windows invisible and hotkeys, event taps, keyboard mapping, menu bar, dock, wallpaper, and notifications stubbed,
and writes the tables to \$OUT/report.md. Settings: RUNS (3), SETTLE seconds (120), JOBS in parallel (4), CYCLES (20), STAGGER seconds between launches (3)."

app="$(cd "${APP:-build/Gary.app}" && pwd)"
runs="${RUNS:-3}"
settle="${SETTLE:-120}"
jobs="${JOBS:-4}"
cycles="${CYCLES:-20}"
stagger="${STAGGER:-3}"
out="${OUT:-tmp/memory/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
config="$HOME/.config/gary"
support="$HOME/Library/Application Support/Gary"
scenarios=("$@")
[[ ${#scenarios[@]} -eq 0 ]] && scenarios=(floor all plugins without effect growth attribution)
[[ "${scenarios[0]}" == -h || "${scenarios[0]}" == --help ]] && echo "$usage" && exit 0

expanded=()
for scenario in "${scenarios[@]}"; do
    case "$scenario" in
    plugins | without)
        while read -r id; do expanded+=("${scenario/plugins/plugin}:$id"); done < <(python3 -c '
import json, sys
shell = json.load(open(sys.argv[1]))
for id in [id for ids in shell.get("bar", {}).values() if isinstance(ids, list) for id in ids] + shell.get("plugins", []):
    print(id)' "$config/shell.json")
        ;;
    effect) expanded+=(effect:plain-widget effect:effect-widget effect:plain-service effect:effect-service effect:both) ;;
    floor | all | growth | attribution | timeline | plugin:* | without:* | effect:*) expanded+=("$scenario") ;;
    *) echo "$usage" >&2 && exit 64 ;;
    esac
done

build="$out/build"
mkdir -p "$build"
cat >"$build/DisplayServices.tbd" <<'EOF'
--- !tapi-tbd
tbd-version:     4
targets:         [ arm64-macos, arm64e-macos ]
install-name:    '/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/A/DisplayServices'
exports:
  - targets:         [ arm64-macos, arm64e-macos ]
    symbols:         [ _DisplayServicesSetBrightness ]
...
EOF
clang -dynamiclib -fobjc-arc -O1 -w -o "$build/probe.dylib" scripts/memory-probe.m "$build/DisplayServices.tbd" -undefined dynamic_lookup \
    -framework AppKit -framework Carbon -framework JavaScriptCore -framework IOKit -framework UserNotifications -framework ApplicationServices
cat >"$build/phys.c" <<'EOF'
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv)
{
    struct rusage_info_v6 usage;
    if (argc < 2 || proc_pid_rusage(atoi(argv[1]), RUSAGE_INFO_V6, (rusage_info_t *)&usage)) return 1;
    printf("{\"phys_footprint\":%llu,\"peak\":%llu}\n", usage.ri_phys_footprint, usage.ri_lifetime_max_phys_footprint);
    return 0;
}
EOF
clang -O1 -o "$build/phys" "$build/phys.c"
login_path="$("$(dscl . -read "$HOME" UserShell | awk '{print $2}')" -l -c 'exec /usr/bin/printenv PATH')"
rm -rf "$build/packages"
/bin/cp -cR "$support/packages" "$build/packages"

plugin() {
    local name="memory.$2-$3" kind entry
    kind="$([[ "$3" == widget ]] && echo bar-widget || echo service)"
    entry="$([[ "$3" == widget ]] && echo widget.tsx || echo service.ts)"
    mkdir -p "$1/$name"
    echo "{ \"schemaVersion\": 1, \"id\": \"$name\", \"name\": \"$name\", \"version\": \"0.1.0\", \"kinds\": [\"$kind\"], \"entryPoints\": { \"$kind\": \"$entry\" } }" \
        >"$1/$name/manifest.json"
    case "$2-$3" in
    plain-widget) echo 'export default { render() { return <text>p</text>; } };' ;;
    effect-widget) echo 'import { Effect } from "gary:effect";
const value = Effect.runSync(Effect.succeed("e"));
export default { render() { return <text>{value}</text>; } };' ;;
    plain-service) echo 'export default { methods: {} };' ;;
    effect-service) echo 'import { Effect } from "gary:effect";
export default { effect: Effect.void };' ;;
    esac >"$1/$name/$entry"
}

prepare() {
    local home="$1" scenario="$2"
    mkdir -p "$home/.config/gary" "$home/.config/fish" "$home/Library/Application Support/Gary" "$home/Library/Logs"
    printf "set -gx PATH (string split : -- '%s')\n" "$login_path" >"$home/.config/fish/config.fish"
    printf "export PATH='%s'\n" "$login_path" | tee "$home/.zprofile" >"$home/.bash_profile"
    for file in theme.json palette.toml; do
        [[ -f "$config/$file" ]] && cp "$config/$file" "$home/.config/gary/"
    done
    [[ -d "$config/plugins" ]] && cp -R "$config/plugins" "$home/.config/gary/plugins"
    for variant in plain-widget effect-widget plain-service effect-service; do
        plugin "$home/.config/gary/plugins" "${variant%-*}" "${variant#*-}"
    done
    echo '{"missing":["accessibility","audio-capture","automation","bluetooth","calendars","full-disk-access","location","notifications","screen-recording"]}' \
        >"$home/Library/Application Support/Gary/onboarding.json"
    ln -s "$build/packages" "$home/Library/Application Support/Gary/packages"
    [[ -d "$HOME/Applications" ]] && ln -s "$HOME/Applications" "$home/Applications"
    [[ -d "$HOME/.config/dinky" ]] && ln -s "$HOME/.config/dinky" "$home/.config/dinky"
    mkdir -p "$home/Library/Group Containers"
    [[ -d "$HOME/Library/Group Containers/group.com.apple.usernoted" ]] &&
        ln -s "$HOME/Library/Group Containers/group.com.apple.usernoted" "$home/Library/Group Containers/group.com.apple.usernoted"
    [[ -d "$HOME/Library/DoNotDisturb" ]] && ln -s "$HOME/Library/DoNotDisturb" "$home/Library/DoNotDisturb"
    [[ -d "$HOME/Library/Application Support/Theme Switcher" ]] &&
        ln -s "$HOME/Library/Application Support/Theme Switcher" "$home/Library/Application Support/Theme Switcher"
    python3 - "$scenario" "$config/shell.json" >"$home/.config/gary/shell.json" <<'EOF'
import json, sys
scenario = sys.argv[1]
shell = json.load(open(sys.argv[2]))
sections = ["left", "center", "right", "notchLeft"]
bar = {section: [] for section in sections}
plugins = []
if scenario in ("all", "growth", "attribution", "timeline"):
    bar = {section: shell.get("bar", {}).get(section, []) for section in sections}
    plugins = shell.get("plugins", [])
elif scenario.startswith("plugin:"):
    id = scenario.split(":", 1)[1]
    bar = {section: [each for each in shell.get("bar", {}).get(section, []) if each == id] for section in sections}
    plugins = [each for each in shell.get("plugins", []) if each == id]
elif scenario.startswith("without:"):
    id = scenario.split(":", 1)[1]
    bar = {section: [each for each in shell.get("bar", {}).get(section, []) if each != id] for section in sections}
    plugins = [each for each in shell.get("plugins", []) if each != id]
elif scenario.startswith("effect:"):
    variant = scenario.split(":", 1)[1]
    if variant in ("plain-widget", "effect-widget", "both"):
        bar["right"] = ["memory.plain-widget" if variant == "plain-widget" else "memory.effect-widget"]
    if variant in ("plain-service", "effect-service", "both"):
        plugins = ["memory.plain-service" if variant == "plain-service" else "memory.effect-service"]
result = {"bar": bar, "plugins": plugins, "packages": shell.get("packages", [])}
settings = {id: value for id, value in shell.get("settings", {}).items()
            if scenario in ("all", "growth", "attribution", "timeline") or scenario == f"plugin:{id}" or (scenario.startswith("without:") and scenario != f"without:{id}")}
if settings:
    result["settings"] = settings
json.dump(result, sys.stdout, indent=2)
sys.stdout.write("\n")
EOF
}

relieve() {
    local dir="$1" label="$2"
    probe "$dir" "$label-gc" gc
    sleep 5
    phys "$dir" "$label-gc"
    probe "$dir" "$label-release" release
    sleep 2
    phys "$dir" "$label-release"
    probe "$dir" "$label-code" code
    sleep 2
    phys "$dir" "$label-code"
}

phys() {
    "$build/phys" "$(cat "$1/pid")" >"$1/$2.phys.json"
}

probe() {
    local dir="$1" label="$2" kind="$3"
    rm -f "$dir/probe.json"
    notifyutil -p "gary.memory-probe.$(cat "$dir/pid").$kind"
    for _ in $(seq 100); do
        [[ -f "$dir/probe.json" ]] && break
        sleep 0.1
    done
    mv "$dir/probe.json" "$dir/$label.jsc.json"
}

deep() {
    local dir="$1" label="$2" pid
    pid="$(cat "$dir/pid")"
    footprint -p "$pid" -f bytes --json "$dir/$label.footprint.json" >/dev/null 2>&1
    vmmap --summary "$pid" >"$dir/$label.vmmap.txt" 2>/dev/null || true
    heap -sortBySize "$pid" >"$dir/$label.heap.txt" 2>/dev/null || true
}

send() {
    python3 - "$(cat "$1/tmpdir")/gary.sock" "$2" "$3" <<'EOF'
import json, socket, sys
path, verb, argument = sys.argv[1:]
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(10)
client.connect(path)
client.sendall((json.dumps({"verb": verb, "args": [argument]}) + "\n").encode())
reply = b""
while not reply.endswith(b"\n"):
    chunk = client.recv(4096)
    if not chunk:
        break
    reply += chunk
if not json.loads(reply or b"{}").get("ok"):
    sys.exit(f"{verb} {argument}: {reply.decode().strip()}")
EOF
}

cycle() {
    local dir="$1" count="$2"
    for _ in $(seq "$count"); do
        send "$dir" summon sndrgrdn.launcher
        sleep 1
        send "$dir" hide sndrgrdn.launcher
        sleep 0.5
        send "$dir" summon sndrgrdn.audio
        sleep 1
        send "$dir" hide sndrgrdn.audio
        sleep 0.5
    done
}

launch() {
    local dir="$1" tmpdir
    shift
    tmpdir="$(mktemp -d /tmp/gary-memory.XXXXXX)"
    echo "$tmpdir" >"$dir/tmpdir"
    env CFFIXED_USER_HOME="$dir/home" HOME="$dir/home" GARY_PROBE_TMPDIR="$tmpdir/" GARY_PROBE_DIR="$dir" \
        DYLD_INSERT_LIBRARIES="$build/probe.dylib" "$@" "$app/Contents/MacOS/gary" app >"$dir/gary.log" 2>&1 &
    echo $! >"$dir/pid"
    for _ in $(seq 300); do
        grep -q "ready pid=" "$dir/gary.log" && return 0
        sleep 0.1
    done
    echo "$dir: Gary did not get ready" >&2
    return 1
}

quit() {
    local dir="$1" pid children
    [[ -f "$dir/pid" ]] || return 0
    pid="$(cat "$dir/pid")"
    children="$(ps -A -o pid=,ppid=,command= | awk -v parent="$pid" '$2 == parent { $2 = ""; print }')"
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 50); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    while read -r child command; do
        [[ -n "$child" && "$(ps -o command= -p "$child" 2>/dev/null)" == "$command" ]] && kill -TERM "$child" 2>/dev/null || true
    done <<<"$children"
    rm -rf "$(cat "$dir/tmpdir")" "$dir/home" "$dir/pid"
}

run() {
    local scenario="$1" round="$2" dir
    dir="$out/runs/$scenario/$round"
    rm -rf "$dir"
    mkdir -p "$dir"
    trap "quit '$dir'" EXIT
    prepare "$dir/home" "$scenario"
    cp "$dir/home/.config/gary/shell.json" "$dir/shell.json"
    local environment=()
    [[ "$scenario" == attribution ]] && environment=(MallocStackLogging=lite)
    launch "$dir" "${environment[@]}"
    if [[ "$scenario" == timeline ]]; then
        for second in $(seq 0 5 300); do
            phys "$dir" "t$(printf %03d "$second")"
            sleep 5
        done
        return 0
    fi
    sleep "$settle"
    phys "$dir" settled
    probe "$dir" settled stats
    case "$scenario" in
    all)
        deep "$dir" settled
        relieve "$dir" settled
        deep "$dir" settled-code
        ;;
    growth)
        local total=0 step
        for step in 1 "$cycles" "$cycles"; do
            cycle "$dir" "$step"
            total=$((total + step))
            sleep "$settle"
            phys "$dir" "cycles$total"
            probe "$dir" "cycles$total" stats
        done
        deep "$dir" "cycles$total"
        relieve "$dir" "cycles$total"
        ;;
    attribution)
        deep "$dir" settled
        malloc_history "$(cat "$dir/pid")" -callTree -invert -ignoreThreads >"$dir/settled.calltree.txt" 2>/dev/null || true
        ;;
    *) relieve "$dir" settled ;;
    esac
}

echo "memory: ${#expanded[@]} scenarios, $runs runs, settle ${settle}s, $jobs at a time, output $out"
for round in $(seq "$runs"); do
    for scenario in "${expanded[@]}"; do
        if [[ "$round" -gt 1 && ("$scenario" == growth || "$scenario" == attribution || "$scenario" == timeline) ]]; then
            continue
        fi
        while [[ "$(jobs -rp | wc -l)" -ge "$jobs" ]]; do wait -n || true; done
        run "$scenario" "$round" &
        sleep "$stagger"
    done
done
wait
python3 scripts/memory-table.py "$out" >"$out/report.md"
echo "memory: wrote $out/report.md"
