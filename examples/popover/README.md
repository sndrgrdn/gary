# Popover

A bar widget with a counter and a panel that opens below it. A click toggles the panel, which has `attach` set so it opens centred below the widget. Scrolling over the widget counts up and down, a right click changes its color, a middle click resets the count, and resting the pointer on it shows a tooltip. The widget publishes the count, and the panel subscribes to the plugin's own id to show it.

Add it to the bar with `gary plugin new you.popover --from popover`.
