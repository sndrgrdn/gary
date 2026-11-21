# Disk

A service and a bar widget in one plugin. The service runs `df` every five minutes and publishes the result under the plugin's id. The widget subscribes to that id, shows the used percentage, and switches to free space when you click it.

Refresh it now with `gary call example.disk refresh`.
