# Themes

Gary's look comes from three layers. Each layer builds on the one before it:

1. A **palette** of named colors, from `~/.config/gary/palette.toml`, or Gary's built-in palette.
2. The **theme**: Gary's built-in `theme.json`, which maps palette colors to theme colors, and defines styles, fonts, spacing, and corner radii.
3. Your **theme changes** in `~/.config/gary/theme.json`, which Gary merges over the built-in theme.

Plugins name theme styles and colors, such as `style="dim"` or `color="accent"`, so a new palette recolors every plugin. Gary applies a saved change to either file at once.

## Set the palette

`palette.toml` has one `key = "value"` line per color, in the format of an Omarchy theme's `colors.toml`:

```toml
mode = "dark"
background = "#1a1b26"
foreground = "#a9b1d6"
accent = "#7aa2f7"
dark_foreground = "#565f89"
bright_foreground = "#c0caf5"
lighter_background = "#24283b"
green = "#9ece6a"
red = "#f7768e"
```

- Colors are `#rgb`, `#rrggbb`, or `#rrggbbaa`. Any key works, and `theme.json` and plugins can name it.
- `background`, `foreground`, and `accent` fall back to the built-in palette when the file leaves them out.
- `mode` is `light` or `dark`. Without it, Gary takes the mode from the lightness of `background`.
- Without the file, Gary uses a built-in dark or light palette that follows the macOS appearance.

## Change the theme

Put only the keys that you change in `~/.config/gary/theme.json`. Gary merges objects key by key, so this file changes the accent color and gives every panel, overlay, and menu a glass material:

```json
{
  "colors": { "accent": "red" },
  "styles": { "surface": { "material": "glass", "background": "alpha(panel, 0.4)" } }
}
```

Add `"$schema": "https://raw.githubusercontent.com/sndrgrdn/gary/main/schemas/theme.schema.json"` to `theme.json`, and your editor completes its keys and marks typos, unknown font weights, and unknown style properties.

`gary skill show theme` lists the styles, colors, and fonts of the installed theme. `gary doctor` reports theme values that do not resolve, and Gary logs them.

### Colors

A theme color maps to a color expression. An expression is a palette or theme color name, a hex color, or one of these functions:

| Expression       | Gives                                          |
| ---------------- | ---------------------------------------------- |
| `mix(a, b, 0.3)` | `a` mixed with 30% of `b`.                     |
| `alpha(a, 0.4)`  | `a` at 40% opacity.                            |
| `contrast(a)`    | Black or white, whichever reads better on `a`. |

A list, such as `["bright_foreground", "mix(foreground, contrast(background), 0.4)"]`, uses the first entry that resolves with the palette. The built-in theme defines `background`, `foreground`, `accent`, `dim`, `bright`, `good`, `bad`, `panel`, `border`, `secondary`, `control`, `on-accent`, `hover`, `selected`, `scrim`, which dims the screen behind a picker, and `bar`, the bar's background.

### Styles

A style is a set of node style properties, such as `{ "color": "dim", "font": "mono" }`. A node names it with `style`. The built-in theme has styles for text, such as `dim`, `bright`, `title`, and `mono`, and for controls, such as `button`, `primary`, and `hover`. `selected` marks the current item, such as the output that plays. `highlight` marks the row that the keyboard or pointer is on in a picker, and `picker` paints the picker's card. Some styles paint what Gary draws itself:

- `surface` paints every panel, overlay, and menu whose `background` is `"solid"`, the default.
- `tooltip` paints node tooltips.
- `toast`, `toast-title`, `toast-body`, and `toast-icon` paint the cards that `host.toast` shows.

A style's `radius` can name an entry of the radius scale, such as `"control"`.

### Fonts

A font is `{ "family": "system", "size": 13, "weight": "regular" }`. `family` is `system`, `monospaced`, or the name of an installed font. `weight` is one of `ultralight`, `thin`, `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`, and `black`. The built-in theme defines `body`, `strong`, `title`, and `mono`, and you can add your own, such as a Nerd Font for icons. `bar.fonts` replaces fonts of the same name inside the bar, so bar widgets can use a monospaced font while panels keep the system font.

### Spacing, radii, and the bar

Plugins read these values, in points, from `state.theme.spacing` and `state.theme.radius`, so changing them respaces and rounds every plugin alike:

| Key               | Default           | Sets                                                                                                  |
| ----------------- | ----------------- | ----------------------------------------------------------------------------------------------------- |
| `spacing.item`    | `8`               | The gap between an icon and its label, and inside rows.                                               |
| `spacing.section` | `16`              | Panel padding and the gap between blocks.                                                             |
| `spacing.edge`    | `20`              | How far surfaces stay inside the display.                                                             |
| `radius.control`  | `6`               | Rows, buttons, and other controls.                                                                    |
| `radius.surface`  | `12`              | Panels, menus, toasts, and cards.                                                                     |
| `bar.height`      | `32`              | The bar's height.                                                                                     |
| `bar.gap`         | `spacing.section` | The gap between bar widgets. `0` lets widgets that draw their own fixed-width slots sit side by side. |
| `bar.edge`        | `spacing.edge`    | How far the bar's left and right sections sit from the display's edges.                               |

## Change the theme from a plugin or script

`gary applyTheme '<json>'` applies theme changes over the built-in theme until Gary restarts, such as `gary applyTheme '{"colors": {"accent": "#ff8800"}}'`. Where your `theme.json` sets the same key, your file wins. `gary applyTheme` without a payload drops the changes and reads the files again.

A theme switcher can write `palette.toml` from a theme library. The [`sndrgrdn.theme`](https://github.com/sndrgrdn/gary-plugins/tree/main/sndrgrdn.theme) plugin does this for Omarchy themes, and sets the wallpaper to match.
