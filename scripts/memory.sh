#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage="usage: scripts/memory.sh [floor | all | gate | images | plugins | plugin:<id> | without | without:<id> | effect | growth | attribution | timeline] ...
Runs a private Gary from a copy of \$APP (default build/Gary.app), re-signed to load the probe library, per scenario, each with its own home, config, lock, and socket,
with MallocSpaceEfficient=1 as the supervisor sets it, windows invisible and hotkeys, event taps, keyboard mapping, menu bar, dock, wallpaper, and notifications stubbed,
weather answered from one cached open-meteo response, and ~/Library/Caches shared by the runs of one side after a short warm-up run,
and writes the tables to \$OUT/report.md.
gate runs all plugins and records the footprint at SETTLE, idle CPU over the next IDLE seconds, startup wall time and CPU
until every bar widget loaded, the launcher, audio menu, and theme picker opened twice each, and the footprint REOPEN seconds after the launcher opened.
images opens and closes the theme picker three times, waits KEEP seconds, opens it once more, then opens the launcher, listing
apps on an empty query, twice, and records each open's time and, 5 s after each close, the footprint by category and the images decoded.
SIDES names builds to compare, alternating per round; side <name> runs APP_<name>, with PLUGINS_<name> as the gary-plugins checkout
and ENV_<name> as extra environment (for example GARY_PROBE_ALLOC_MB=5 or GARY_PROBE_BUSY_MS=50).
Settings: RUNS (3), SETTLE seconds (120), IDLE seconds (60), REOPEN seconds (90), KEEP seconds (65), JOBS in parallel (4), CYCLES (20), STAGGER seconds between launches (3)."

read -r -a sides <<<"${SIDES:-main}"
runs="${RUNS:-3}"
settle="${SETTLE:-120}"
idle="${IDLE:-60}"
reopen="${REOPEN:-90}"
keep="${KEEP:-65}"
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
    floor | all | gate | images | growth | attribution | timeline | plugin:* | without:* | effect:*) expanded+=("$scenario") ;;
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
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <unistd.h>
static double cpu(struct rusage_info_v6 *usage)
{
    mach_timebase_info_data_t base;
    mach_timebase_info(&base);
    return (double)(usage->ri_user_time + usage->ri_system_time) * base.numer / base.denom / 1e9;
}
static double wall(void)
{
    struct timeval now;
    gettimeofday(&now, NULL);
    return now.tv_sec + now.tv_usec / 1e6;
}
int main(int argc, char **argv)
{
    struct rusage_info_v6 usage;
    struct proc_bsdinfo info;
    if (argc < 2) return 1;
    int pid = atoi(argv[1]);
    if (argc == 4) {
        double until = wall() + atof(argv[2]);
        while (wall() < until && !proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&usage)) {
            printf("%.6f %.6f\n", wall(), cpu(&usage));
            fflush(stdout);
            usleep(atoi(argv[3]) * 1000);
        }
        return 0;
    }
    if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&usage)) return 1;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) != sizeof info) return 1;
    printf("{\"phys_footprint\":%llu,\"peak\":%llu,\"cpu\":%.6f,\"start\":%.6f,\"time\":%.6f}\n", usage.ri_phys_footprint,
           usage.ri_lifetime_max_phys_footprint, cpu(&usage), info.pbi_start_tvsec + info.pbi_start_tvusec / 1e6, wall());
    return 0;
}
EOF
clang -O1 -o "$build/phys" "$build/phys.c"
login_path="$("$(dscl . -read "$HOME" UserShell | awk '{print $2}')" -l -c 'exec /usr/bin/printenv PATH')"
for side in "${sides[@]}"; do
    app="APP_$side"
    [[ -n "${!app:-}" || "$side" == main ]] || { echo "side $side has no APP_$side" >&2 && exit 64; }
    rm -rf "$build/packages-$side" "$build/caches-$side" "$build/$side.app" "$build/$side.entitlements"
    /bin/cp -cR "${!app:-${APP:-build/Gary.app}}" "$build/$side.app"
    codesign -d --entitlements - --xml "$build/$side.app" >"$build/$side.entitlements" 2>/dev/null
    [[ -s "$build/$side.entitlements" ]] || plutil -create xml1 "$build/$side.entitlements"
    for entitlement in allow-dyld-environment-variables disable-library-validation; do
        /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.$entitlement bool true" "$build/$side.entitlements"
    done
    codesign --force --options runtime --entitlements "$build/$side.entitlements" \
        --sign "$(codesign -dvv "$build/$side.app" 2>&1 | sed -n 's/^Authority=//p' | head -1)" "$build/$side.app" 2>/dev/null
    mkdir -p "$build/caches-$side"
    /bin/cp -cR "$support/packages" "$build/packages-$side"
    plugins="PLUGINS_$side"
    if [[ -n "${!plugins:-}" ]]; then
        rsync -a --delete --exclude .git --exclude node_modules "${!plugins}/" "$build/packages-$side/git/github.com/sndrgrdn/gary-plugins/"
    fi
done
echo "${sides[*]}" >"$out/sides"
mkdir -p "$build/fetch"
curl -fsS --max-time 20 -o "$build/fetch/api.open-meteo.com" \
    "https://api.open-meteo.com/v1/forecast?latitude=53.2&longitude=5.8&current=temperature_2m,weather_code,is_day&hourly=temperature_2m&forecast_hours=13&timezone=auto"

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
    local home="$1" scenario="$2" side="$3"
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
    ln -s "$build/packages-$side" "$home/Library/Application Support/Gary/packages"
    [[ -d "$HOME/Applications" ]] && ln -s "$HOME/Applications" "$home/Applications"
    [[ -d "$HOME/.config/dinky" ]] && ln -s "$HOME/.config/dinky" "$home/.config/dinky"
    ln -s "$build/caches-$side" "$home/Library/Caches"
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
if scenario in ("all", "gate", "images", "growth", "attribution", "timeline"):
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
            if scenario in ("all", "gate", "images", "growth", "attribution", "timeline") or scenario == f"plugin:{id}" or (scenario.startswith("without:") and scenario != f"without:{id}")}
if scenario == "images":
    settings["sndrgrdn.launcher"] = {**settings.get("sndrgrdn.launcher", {}), "minimal": False}
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
    python3 - "$(cat "$1/tmpdir")/gary.sock" "$2" "$3" "${4:-}" <<'EOF'
import json, socket, sys, time
path, verb, argument, timing = sys.argv[1:]
started = time.time()
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
if timing:
    json.dump({"ms": (time.time() - started) * 1000}, open(timing, "w"))
EOF
}

respond() {
    python3 - "$(cat "$1/tmpdir")/gary.sock" "$2" >"$1/respond-$2.json" <<'EOF'
import json, socket, sys, time
path, plugin = sys.argv[1:]
def send(verb):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(10)
    client.connect(path)
    client.sendall((json.dumps({"verb": verb, "args": [plugin]}) + "\n").encode())
    reply = b""
    while not reply.endswith(b"\n"):
        chunk = client.recv(4096)
        if not chunk:
            break
        reply += chunk
    return json.loads(reply or b"{}").get("ok") is True
result = {"errors": 0}
for open in ("open1", "open2"):
    started = time.time()
    shown = send("summon")
    result[open] = (time.time() - started) * 1000
    time.sleep(1)
    result["errors"] += (not shown) + (not send("hide"))
    time.sleep(1)
json.dump(result, sys.stdout)
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
    local dir="$1" side="$2" tmpdir app extra="ENV_$2"
    shift 2
    tmpdir="$(mktemp -d /tmp/gary-memory.XXXXXX)"
    echo "$tmpdir" >"$dir/tmpdir"
    read -r -a extra <<<"${!extra:-}"
    app="$build/$side.app"
    env CFFIXED_USER_HOME="$dir/home" HOME="$dir/home" MallocSpaceEfficient=1 GARY_PROBE_TMPDIR="$tmpdir/" GARY_PROBE_DIR="$dir" GARY_PROBE_FETCH_CACHE="$build/fetch" \
        DYLD_INSERT_LIBRARIES="$build/probe.dylib" "${extra[@]}" "$@" "$app/Contents/MacOS/gary" app >"$dir/gary.log" 2>&1 &
    echo $! >"$dir/pid"
    "$build/phys" $! 20 10 >"$dir/startup.cpu" &
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
    rm -rf "$(cat "$dir/tmpdir")" "${dir:?}/home" "$dir/pid"
}

run() {
    local scenario="$1" side="$2" round="$3" dir settle="$settle" idle="$idle" reopen="$reopen"
    dir="$out/$([[ "$round" == 0 ]] && echo warmup || echo runs)/$scenario$([[ "$side" == main ]] || echo "@$side")/$round"
    [[ "$round" == 0 ]] && settle=20 idle=0 reopen=0
    rm -rf "$dir"
    mkdir -p "$dir"
    running="$dir"
    trap 'quit "$running"' EXIT
    prepare "$dir/home" "$scenario" "$side"
    cp "$dir/home/.config/gary/shell.json" "$dir/shell.json"
    local environment=()
    [[ "$scenario" == attribution ]] && environment=(MallocStackLogging=lite)
    launch "$dir" "$side" "${environment[@]}"
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
    gate)
        sleep "$idle"
        phys "$dir" idle
        respond "$dir" sndrgrdn.launcher
        sleep "$reopen"
        phys "$dir" launcher
        respond "$dir" sndrgrdn.audio
        respond "$dir" sndrgrdn.theme
        ;;
    images)
        local opened
        for opened in theme1 theme2 theme3 waited theme4 launcher1 launcher2; do
            if [[ "$opened" == waited ]]; then
                sleep "$keep"
            else
                send "$dir" summon "sndrgrdn.${opened%?}" "$dir/$opened.open.json"
                sleep 2
                send "$dir" hide "sndrgrdn.${opened%?}"
                sleep 5
            fi
            phys "$dir" "$opened"
            probe "$dir" "$opened" stats
            footprint -p "$(cat "$dir/pid")" -f bytes --json "$dir/$opened.footprint.json" >/dev/null 2>&1
        done
        ;;
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

echo "memory: ${#expanded[@]} scenarios, ${#sides[@]} sides (${sides[*]}), $runs runs, settle ${settle}s, $jobs at a time, output $out"
for side in "${sides[@]}"; do
    run "${expanded[0]}" "$side" 0 &
    sleep "$stagger"
done
wait
for round in $(seq "$runs"); do
    order=("${sides[@]}")
    if ((round % 2 == 0)); then
        order=()
        for ((index = ${#sides[@]} - 1; index >= 0; index--)); do order+=("${sides[index]}"); done
    fi
    for scenario in "${expanded[@]}"; do
        if [[ "$round" -gt 1 && ("$scenario" == growth || "$scenario" == attribution || "$scenario" == timeline) ]]; then
            continue
        fi
        for side in "${order[@]}"; do
            while [[ "$(jobs -rp | wc -l)" -ge "$jobs" ]]; do wait -n || true; done
            run "$scenario" "$side" "$round" &
            sleep "$stagger"
        done
    done
done
wait
python3 scripts/memory-table.py "$out" >"$out/report.md"
echo "memory: wrote $out/report.md"
