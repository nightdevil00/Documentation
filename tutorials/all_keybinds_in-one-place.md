# Guide: Bringing all Omarchy keybinds into your local config

This copies Omarchy's packaged keybindings into `~/.config/hypr/` so you can read and edit them in one place, then loads them.

## 1. Find the source bindings
Omarchy keeps defaults (read-only) here:
```
/usr/share/omarchy/default/hypr/bindings/
```
List them:
```bash
ls /usr/share/omarchy/default/hypr/bindings/
```
You'll see `applications.lua`, `clipboard.lua`, `media.lua`, `tiling.lua`, `utilities.lua`, `voxtype.lua`.

## 2. Create a local bindings folder and copy them
```bash
mkdir -p ~/.config/hypr/bindings
cp /usr/share/omarchy/default/hypr/bindings/*.lua ~/.config/hypr/bindings/
```
These are now yours to edit. `~/.config/hypr/bindings/*.lua` resolves to Lua requires as `hypr.bindings.<name>`.

## 3. Load them from your `bindings.lua`
Replace the top of `~/.config/hypr/bindings.lua` with requires for each file (keep any personal overrides after):
```lua
require("hypr.bindings.media")
require("hypr.bindings.clipboard")
require("hypr.bindings.tiling")
require("hypr.bindings.utilities")
require("hypr.bindings.voxtype")
require("hypr.bindings.applications")

-- Your personal overrides go here, e.g.:
-- o.bind("SUPER + B", "System monitor", "foot -e btop")
```

## 4. Disable the packaged defaults (avoid duplicate binds)
In `~/.config/hypr/hyprland.lua`, set the flag **before** `require("default.hypr.omarchy")`:
```lua
omarchy_default_bindings = false
```
(It's already there as a commented line — uncomment it.)

## 5. Reload and validate
```bash
hyprctl reload
hyprctl configerrors      # must be empty
```

## 6. Verify
```bash
omarchy menu keybindings --print
```

## Notes
- Edit any file under `~/.config/hypr/bindings/` and save — Hyprland hot-reloads automatically.
- To change an existing key, `hl.unbind("SUPER + F")` first, then `o.bind(...)` again.
- If something breaks, reset with `omarchy refresh hyprland` (backs up first).
