#!/usr/bin/env python3
import json, os, re, shutil, subprocess, sys, time

log, gary, screenshot = sys.argv[1], sys.argv[2], sys.argv[3]
config = os.path.expanduser("~/.config/gary")
plugins = os.path.join(config, "plugins")
shell = os.path.join(config, "shell.json")
created_plugins = not os.path.exists(plugins)
cases = {
    "runaway.load": "module.exports = { render() { while (true) {} } };\n",
    "runaway.later": "var renders = 0;\nmodule.exports = { render(state) { if (renders++ > 0) { while (true) {} } "
                     "return { type: \"text\", text: \"loops on the next tick\", style: \"bad\" }; } };\n",
}
layout = {"bar": {"left": ["gary.workspaces"], "center": list(cases), "right": ["gary.battery", "gary.clock"]}}


def listing():
    rows = subprocess.run([gary, "listPlugins"], capture_output=True, text=True).stdout.splitlines()
    return {row.split("\t")[0]: row.split("\t")[-1] for row in rows}


def failed_at(id):
    for line in open(log).read().splitlines():
        if f"plugin {id}/bar-widget: failed:" in line and float(line.split()[0]) >= started:
            return float(line.split()[0]), line.split("failed: ", 1)[1]
    return None, None


if os.path.exists(shell) or any(os.path.exists(os.path.join(plugins, id)) for id in cases):
    sys.exit("refusing to overwrite shell.json or a runaway plugin")
started = time.time()
try:
    for id, source in cases.items():
        os.makedirs(os.path.join(plugins, id))
        manifest = {"schemaVersion": 1, "id": id, "name": id, "version": "0.1.0", "kinds": ["bar-widget"],
                    "entryPoints": {"bar-widget": "widget.js"}, "subscribes": ["clock"]}
        with open(os.path.join(plugins, id, "manifest.json"), "w") as file:
            json.dump(manifest, file)
        with open(os.path.join(plugins, id, "widget.js"), "w") as file:
            file.write(source)
    with open(shell, "w") as file:
        json.dump(layout, file)
    time.sleep(1)
    subprocess.run(["screencapture", "-x", "-R0,0,1728,40", screenshot.replace(".png", "-before-tick.png")])
    print("listPlugins after load:", json.dumps(listing()))
    deadline = time.time() + 75
    while time.time() < deadline and failed_at("runaway.later")[0] is None:
        time.sleep(0.5)
    time.sleep(2)
    subprocess.run(["screencapture", "-x", "-R0,0,1728,40", screenshot])
    final = listing()
    print("listPlugins after tick:", json.dumps(final))
    for id in cases:
        at, reason = failed_at(id)
        print(f"{id} failed_at={at} after_start_s={(at - started) if at else float('nan'):.2f} reason={reason!r} state={final.get(id)}")
    clock = [(float(t), cause, tree) for t, cause, tree in
             re.findall(r"^(\d+\.\d+) commit plugin=gary\.clock \S+ cause=(\S+) .* tree=(.*)$", open(log).read(), re.M)
             if float(t) >= started]
    for t, cause, tree in clock:
        print(f"clock commit at={t:.3f} cause={cause} tree={tree}")
    later_failed = failed_at("runaway.later")[0]
    after = [t for t, cause, _ in clock if cause == "clock" and later_failed and abs(t - later_failed) < 1]
    print(f"VERDICT both_failed={all(failed_at(id)[0] for id in cases)} clock_committed_same_tick={bool(after)} "
          f"clock_tick_to_commit_vs_runaway_failure_ms={((after[0] - later_failed) * 1000) if after else float('nan'):.1f}")
finally:
    os.remove(shell)
    for id in cases:
        shutil.rmtree(os.path.join(plugins, id), ignore_errors=True)
    if created_plugins:
        os.rmdir(plugins)
