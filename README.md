# Control Center for Omarchy

Quick settings for the [Omarchy](https://omarchy.org/) shell: Wi-Fi, Bluetooth, volume, brightness, and power in one popup.

![Control Center panel](preview.png)

## Install

```bash
omarchy plugin add https://github.com/404Prabhat/omarchy-control-center.git --enable
```

## Update / Remove

```bash
omarchy plugin update aryal.control-center
omarchy plugin remove aryal.control-center
```

## Use

Hover the top-left corner (the top-right one opens notification history), or run:

```bash
omarchy-shell shell toggle aryal.control-center
```

Left-click opens a panel, right-click toggles. Edit mode rearranges the grid.

The hover corners take clicks in a 12 px square at the top corners of each screen. To click through a corner (for example a maximized window's close button), set `hoverCorners` on the widget's bar entry in `~/.config/omarchy/shell.json` to `"Top-left only"`, `"Top-right only"`, or `"Off"` (default `"Both"`):

```json
{ "id": "aryal.control-center", "hoverCorners": "Off" }
```

## What you get

- 4×4 grid of toggles, sliders, and actions
- Live volume, brightness, Wi-Fi, and Bluetooth meters
- Battery, weather, and power actions
- Missing tools just hide their tile

## Needs

Omarchy + Quickshell, JetBrainsMono Nerd Font. Optional: `nmcli`, `bluetoothctl`, `gsettings`, `brightnessctl`, `powerprofilesctl`, `foot`, `nautilus`, `btop`, `gnome-control-center` (or `systemsettings` / `xfce4-settings-manager`), `wl-screenrec` / `wf-recorder`, `tormarchy`.

Runs locally as your user, no telemetry.

## Files

`manifest.json` · `Panel.qml` · `Model.js` · `control-center.json` · `EdgeSummon.qml`

## License

MIT — see [LICENSE](LICENSE).
