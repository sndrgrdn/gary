# Launcher

A keyboard-driven app launcher. Control-Option-Space, a manifest hotkey, opens a menu that covers the display with a `backdrop` surface. Typing filters the installed apps from the `apps` capability, the arrow keys and the pointer move the selection, and Return or a click opens the app. Escape or a click outside the card hides it. `keepLoaded` keeps the app list between opens, and each press of the hotkey clears the search and refreshes the list.

Copy it with `gary plugin new you.launcher --from launcher`. Then open it with `gary key you.launcher ctrl+alt+space`, and search and open an app with `gary key you.launcher/menu c a l enter`.
