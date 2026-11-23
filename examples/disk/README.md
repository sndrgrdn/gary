# Disk

A service and a bar widget in one plugin. The service runs `df` every five minutes and publishes the result under the plugin's id. The widget subscribes to that id, shows the used percentage, and switches to free space when you click it.

The service is written with Effect from `gary:effect`: its `effect` repeats the refresh on a schedule, and Gary stops it when the plugin unloads. `topic.ts` types the published value, so the widget reads `state["example.disk"]` with its fields.

Copy it with `gary plugin new you.disk --from disk`, and refresh it with `gary call you.disk refresh`. Run `npm install` in the copy to type-check it.
