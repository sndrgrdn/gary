# OSD

A panel with two surfaces that show at the same time. `main` is a settings panel at the top right with a volume slider and buttons. `osd` is a volume display at the bottom centre that the volume keys, the slider, or a button show, and a timer hides after 1.5 seconds. Both surfaces come from one module, so they share its state, and `render` draws each one by `state.surface`. `keepLoaded` keeps the volume keys working after you close the settings.

Open the settings with `gary summon example.osd`, and the display alone with `gary summon example.osd:osd`. The volume keys need Accessibility for Gary.
