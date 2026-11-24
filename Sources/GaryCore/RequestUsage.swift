import Foundation

public extension Request {
    static let usage: [CommandUsage] = [
        CommandUsage("ping", "Check that Gary is running.", nil),
        CommandUsage("quit", "Stop Gary and its crash supervisor, restoring the menu bar and Dock settings that plugins changed.", nil),
        CommandUsage(
            "summon <plugin>[:<surface>]",
            "Load and show a plugin's panel, overlay or menu. Name a surface to show one other than main.",
            "gary summon you.music:osd",
        ),
        CommandUsage(
            "hide <plugin>[:<surface>]",
            "Hide a plugin's surface, main unless named, and unload the plugin when no surface of its kind stays shown, unless it is keepLoaded.",
            nil,
        ),
        CommandUsage("toggle <plugin>[:<surface>]", "Summon a hidden surface or hide a shown one.", nil),
        CommandUsage("reloadPlugins [plugin]", "Reload one plugin, or every loaded plugin, from disk.", nil),
        CommandUsage("rescanPlugins", "Find added and removed plugin directories.", nil),
        CommandUsage("reloadConfig", "Re-read ~/.config/gary/shell.json.", nil),
        CommandUsage(
            "applyTheme [json]",
            "Apply a theme override payload, or re-read the theme files.",
            ##"gary applyTheme '{"colors": {"accent": "#ff8800"}}'"##,
        ),
        CommandUsage("listPlugins", "List every plugin with its state.", nil),
        CommandUsage("doctor", "Report the version, private API, permissions, plugin and config problems, and other bars that are running.", nil),
        CommandUsage(
            "stats [plugin] [--watch]",
            """
            Print one JSON line per loaded plugin kind with what it costs since it loaded: engine CPU time, entries by cause, renders, \
            timer fires in the last minute, live timers, pending host calls, the longest entry, entries stopped at the time limit, \
            and the nodes, images, views and layers that Gary holds for it. With --watch, print them again every second.
            """,
            "gary stats you.weather --watch",
        ),
        CommandUsage(
            "onboarding",
            "Show the permissions window, which lists what the enabled plugins need, with a Grant button for each. Starts Gary if needed.",
            nil,
        ),
        CommandUsage(
            "permissions",
            "List each macOS permission, whether Gary has it, and the capabilities and enabled plugins that need it. Starts Gary if needed.",
            nil,
        ),
        CommandUsage(
            "permissions request <name>",
            "Show the macOS prompt for a permission, or open its System Settings pane where macOS has no prompt.",
            "gary permissions request screen-recording",
        ),
        CommandUsage(
            "call <plugin> <method> [args...]",
            """
            Call a method a plugin exports, loading it first if needed. Arguments arrive as strings. \
            Gary waits up to 60 seconds for a method that returns a promise. \
            A result that is not a string prints as JSON, and a thrown error or rejected promise prints its message and exits with status 1.
            """,
            "gary call you.weather forecast 3",
        ),
        CommandUsage(
            "action <plugin>/<kind> <action> [payload]",
            """
            Click the shown node of a running kind whose action, rightAction or middleAction has this name, so onAction gets the node's frame \
            as from a real click. Send any other action, such as an input's change, without a frame. The payload is an optional number or text.
            """,
            "gary action you.music/panel volume 0.5",
        ),
        CommandUsage(
            "key <plugin>[/<kind>] <key>...",
            """
            Press keys in order, each named as onKey names it, as the user would. A key that the plugin holds as a hotkey, from its manifest \
            or host.hotkeys, presses that hotkey. \
            Any other key goes to the plugin's focused surface, where an input takes typed characters and onKey gets the rest.
            """,
            "gary key you.launcher s a f enter",
        ),
        CommandUsage(
            "scroll <plugin>/<kind> [action] <dy> [--precise]",
            """
            Scroll by dy over the shown node with this action, or over the surface when no action is named, as the user would, so onScroll gets \
            event.y = dy. A mouse wheel moves in lines; --precise makes a trackpad gesture in points, sent as a began and an ended event.
            """,
            "gary scroll you.music/bar-widget volume 3",
        ),
        CommandUsage(
            "hover <plugin>/<kind> <hoverAction> [off]",
            """
            Move the pointer onto the shown node with this hoverAction, as the user would, so onAction gets the action with true, \
            or with off move it away, so onAction gets false.
            """,
            "gary hover you.launcher/menu row:safari",
        ),
        CommandUsage(
            "click <plugin>/<kind> <x> <y>",
            """
            Click with the left mouse button at a point of the shown surface, in points from its top left corner, as the user would, \
            whether a node with an action, a node without one, or empty space is there.
            """,
            "gary click you.launcher/menu 10 10",
        ),
        CommandUsage(
            "tree <plugin>/<kind>",
            """
            Print the shown nodes of a running kind as an outline: each node's type, key and text, then its frame in points from the top left \
            of its surface, and its color, background, opacity, border and font as drawn now.
            """,
            "gary tree you.launcher/menu",
        ),
        CommandUsage(
            "capture <plugin>/<kind> <file.png>",
            """
            Draw a running kind's shown surface into a PNG at the display's scale, without Screen Recording and without other windows. \
            Blur and materials are left out, since macOS composites them later.
            """,
            "gary capture you.launcher/menu /tmp/launcher.png",
        ),
        CommandUsage(
            "frames [--record <seconds>]",
            """
            Report frame pacing per display: frames, hitch time in ms per second against the display's refresh rate, frame time p50, p99 \
            and max, and for each hitch the main-thread work inside it, such as a plugin's tree, layout, image decode or the Core Animation \
            commit. Gary records frames only while a surface changes or animates. Without --record it summarizes the last 60 seconds; \
            with --record it waits that many seconds and reports only them.
            """,
            "gary frames --record 10",
        ),
        CommandUsage(
            "trace --record <seconds> | --follow [--topics <file>]",
            """
            Print what Gary does as JSON lines in order, each with a monotonic time t in seconds and an ev: each cause with its id, which \
            later events carry as trace; topic publishes with their subscribers and value size; plugin engine entries with their cause and \
            duration; host calls and their completion; renders and tree applies; surface shows and hides; IPC requests; and frame hitches \
            with the main-thread work inside them. --record stops after that many seconds, --follow runs until interrupted. With --topics, \
            also write each published topic value to a file for gary replay. Gary records only while a gary trace runs.
            """,
            "gary trace --record 20 --topics /tmp/topics.jsonl",
        ),
        CommandUsage(
            "replay <file> [plugin]",
            """
            Publish the topic values in a file from gary trace --topics again, in order and with their timing, instead of the live values, \
            and return when done. Without a plugin every subscriber gets them, and Gary stops the replayed topics' capabilities until the \
            replay ends, then starts them again, which publishes the live values. With a plugin only it gets them, and it gets the latest \
            live value again at the end. Each line is a JSON object with a time t in seconds, a topic and a value.
            """,
            "gary replay /tmp/topics.jsonl you.power",
        ),
    ]
}
