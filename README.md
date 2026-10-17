<p align="center">
  <img src="docs/alt-win-swap.png" width="220" alt="Alt / Win swap">
</p>

# Alt / Win Swap (Omarchy plugin)

![Configuration panel](docs/preview.png)

Plugin id: `omarchy-swap-alt-win` (same as the repo/directory) · IPC target:
`swap-alt-win` · Config file: `~/.config/omarchy/swap-alt-win.json`

An Omarchy shell plugin that swaps the **Alt** and **Win/Super** keys with
Hyprland's XKB `altwin` option, and can switch back automatically based on the
**focused app**: add an app to the exception list and the original keys return
while that app is focused, then the swap comes back when you leave.

It is aimed at macOS keyboard habits (the Cmd position) or keyboards whose
physical layout does not match their labels.

- Keeps your existing `kb_options` (for example `compose:caps,ctrl:swapcaps`) and only adds/removes the swap option.
- Supports the inverse mode: swap only inside the listed apps, and leave everything else untouched.
- There is a single engine instance in the service; the bar icon on each monitor is only a view of it.
- Restores your original keys when the plugin is turned off, disabled, or removed.
- Re-learns the baseline and reapplies after hand-editing the config or `hyprctl reload`.

## Requirements

- Omarchy 4 (Hyprland 0.5x, Lua config).
- Writes go through `hyprctl eval`; legacy configs fall back to `hyprctl keyword` automatically.
- No root required, and `~/.config/hypr/input.lua` is not modified.

> **Note:** the swap is global. While it is active, Omarchy's `SUPER` shortcuts
> are triggered by the **physical Alt key**, and `Alt` shortcuts by the physical
> Win key. That is exactly what "swapping the keys" means.

## Installation

Install directly from GitHub (recommended):

```bash
omarchy plugin add https://github.com/zachzhao1984/omarchy-swap-alt-win --enable --yes
```

Install from a local checkout:

```bash
# from this repository's directory
./install.sh                 # install and put the keyboard icon on the right side of the bar
./install.sh --no-enable     # install only
./install.sh --headless      # install and enable as a headless service (no bar widget)
```

Manual installation:

```bash
mkdir -p ~/.config/omarchy/plugins
cp -r . ~/.config/omarchy/plugins/omarchy-swap-alt-win
omarchy plugin validate ~/.config/omarchy/plugins/omarchy-swap-alt-win
omarchy plugin enable omarchy-swap-alt-win --section right
```

Upgrade / reinstall: run `./install.sh` again (it will not enable the plugin
twice).

Headless mode can also be configured by editing `~/.config/omarchy/shell.json`
directly and adding the plugin to the top-level `plugins` array:

```json
{ "id": "omarchy-swap-alt-win" }
```

## Usage

Bar icon (monochrome Alt / Win keycaps with a double-headed arrow):

| Action | Effect |
|--------|--------|
| Left click | Open the configuration panel |
| Right click | Turn the plugin on / off |
| Middle click | Re-read Hyprland state and the focused window |

Icon states:

- Bright = currently swapping (physical Alt triggers Super)
- Dim = original keys: the plugin may be off, or the focused app is an exception

In the panel you can:

- Toggle the master switch
- Choose the exception list from two sources with `Running apps` / `All apps`:
  - `Running apps`: **currently open programs**, in focus order, with app
    icons. Click to add, click again to remove.
  - `All apps`: **every installed program** (read from `.desktop` entries),
    also with app icons, plus a search field. The match rule is
    `StartupWMClass` (or the desktop id when that is absent).
- The `REVERT IN` / `SWAP ONLY IN` header row shows the icons of the selected
  apps (horizontally scrollable). Each icon has a small `×` in its top-right
  corner that removes that app's revert; hover an icon to see the class / rule
  it maps to. `title:` rules, hand-written regexes, and rules for uninstalled
  apps appear as icons here too.
- Toggle "Swap only inside these apps"
- Toggle title matching
- See the current baseline (`kb_options` with the swap removed)

Each row in the list shows the app icon, name, and the window class used for
matching; selected apps are checked. Both lists share the same row style. Long
lists scroll inside the panel (about 4 rows visible; use search to jump). The
panel itself is a keyboard-focusable layer-shell popup, so you can type in the
search field directly; `Esc` closes it.

Command line:

```bash
omarchy-shell swap-alt-win status        # JSON: state, focused window, config
omarchy-shell swap-alt-win enable
omarchy-shell swap-alt-win disable
omarchy-shell swap-alt-win toggle
omarchy-shell swap-alt-win isSwapped     # true/false
omarchy-shell swap-alt-win keyState      # swapped / normal / restore
omarchy-shell swap-alt-win addActive     # add the focused window to the list
omarchy-shell swap-alt-win removeActive
omarchy-shell swap-alt-win setMode revert|only
omarchy-shell swap-alt-win refresh       # re-read
```

### Shortcut (optional)

You can add a master toggle in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + K", "Toggle Alt / Win swap", "omarchy-shell swap-alt-win toggle")
```

While the swap is active, `SUPER` shortcuts follow the physical Alt key, so keep
that in mind when writing the binding.

## Configuration

The first run creates `~/.config/omarchy/swap-alt-win.json`:

```json
{
  "version": 1,
  "enabled": true,
  "mode": "revert",
  "swapOption": "altwin:swap_alt_win",
  "matchTitles": false,
  "apps": ["firefox", "org.gnome.Nautilus", "title:YouTube"]
}
```

| Field | Description |
|-------|-------------|
| `enabled` | Master switch. When `false`, the original keys are restored. |
| `mode` | `revert`: swap by default, restore inside `apps`.<br>`only`: leave keys alone by default, swap inside `apps`. |
| `swapOption` | XKB option. Defaults to `altwin:swap_alt_win` (swaps both sides). You can also use `altwin:swap_lalt_lwin` / `altwin:swap_ralt_rwin` to swap only one side. |
| `matchTitles` | When `true`, plain rules also match window titles. |
| `apps` | Exception / target app list. |

Matching rules:

- Case-insensitive.
- Treated as a regex when possible (for example `firefox|chromium`); falls back
  to a plain substring match when it is not a valid regex.
- Matches the window class (Hyprland's `class`) by default; with
  `matchTitles: true` it also matches titles.
- A `title:` prefix forces title-only matching, for example `title:YouTube`.

You can inspect the window class with
`hyprctl activewindow -j | jq -r .class`, or see it directly in the panel's
`FOCUSED APP` row.

Saved changes take effect automatically (file watcher), or run:

```bash
omarchy-shell swap-alt-win refresh
```

## How it works

- Reads `hyprctl -j getoption input:kb_options` to get the current baseline,
  strips the swap options managed by this plugin, and produces `plainOptions`.
- Swap state = `plainOptions + swapOption`; restore state = the baseline.
- Writes through `hyprctl eval 'hl.config({ input = { kb_options = "..." } })'`.
  Hyprland 0.5x's `hyprctl keyword` does not work with the Lua config parser, so
  the plugin reads the value back to confirm and falls back to the legacy
  `keyword` path when it did not apply.
- Listens to Hyprland socket2's `activewindow` events (including XWayland
  windows) and switches after a 120 ms debounce.
- The `Running apps` list comes from `hyprctl -j clients`: sorted by
  `focusHistoryID`, deduplicated by class, with icons looked up by window class
  / app name in `DesktopEntries`. It is refreshed on focus / open / close events
  and every time the panel opens.
- The `All apps` list comes from Quickshell's `DesktopEntries.applications`,
  sorted by name, with icons resolved through `Quickshell.iconPath()`;
  `Hidden` / `NoDisplay` entries are excluded by default.
- On `configreloaded`, re-learns the baseline (so edits to `input.lua` are
  picked up) and reapplies.
- `Service.qml` is the single engine instance (the shell mounts a plugin's
  service once while it is enabled); `BarWidget.qml` gets the state through
  `bar.shell.serviceFor("omarchy-swap-alt-win")` and forwards actions.

## Known limitations

- `kb_options` is global, so all keyboards are swapped together. To
  differentiate by device, set `kb_options` for a specific keyboard in
  `~/.config/hypr/input.lua` (it overrides the global setting).
- If you are holding Alt/Win/Super at the moment of a switch, a modifier may
  flicker once; release and press it again.
- Some games use raw input or their own key handling; whether the swap applies
  depends on which layer the game reads.
- The bar icon depends on Omarchy's built-in bar; headless mode has no icon.

## Troubleshooting

```bash
hyprctl getoption input:kb_options             # currently active options
omarchy-shell swap-alt-win status              # plugin's view
journalctl --user -b | grep -i swap-alt-win    # plugin logs
```

- The icon is always dim: check that `~/.config/omarchy/shell.json`'s
  `bar.layout` contains `{ "id": "omarchy-swap-alt-win" }`, or run
  `omarchy plugin list | grep omarchy-swap-alt-win`.
- The status shows `error`: usually `hyprctl` is unavailable. Make sure you are
  running inside a Hyprland session.
- `omarchy-shell swap-alt-win status` says `Target not found`: the plugin
  service is not mounted yet (common right after a hot reload). Run
  `omarchy restart shell`; `install.sh` also checks and warns at the end.
- To restore the original keys immediately: right-click the icon, run
  `omarchy-shell swap-alt-win disable`, or
  `omarchy plugin disable omarchy-swap-alt-win`.

## Uninstall

```bash
omarchy plugin disable omarchy-swap-alt-win
omarchy plugin remove omarchy-swap-alt-win
rm -f ~/.config/omarchy/swap-alt-win.json
```

Disabling or removing the plugin writes the original keys back.

## Development

```bash
node --test tests/          # pure-logic tests for Model.js
```

After editing QML the shell hot-reloads plugin files, but loaded components may
be cached. The reliable path is:

```bash
./install.sh --no-enable
omarchy restart shell
```
