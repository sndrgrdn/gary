# Disk

A service and a bar widget in one plugin. The service runs `df` every five minutes and publishes the result under the plugin's id. The widget subscribes to that id, shows the used percentage, and switches to free space when you click it.

The service is written with Effect from `gary:effect`: its `effect` repeats the refresh on a schedule, and Gary stops it when the plugin unloads. Run `npm install effect@4.1.5` in a copy of this folder to type-check it.

Refresh it now with `gary call example.disk refresh`.
