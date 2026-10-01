# Media workspace — a scrolling special workspace of web apps

A named Hyprland special workspace that opens with your social web apps already
running, laid out side by side on the scrolling layout so several are readable
at once instead of being shrunk into slivers.

Written against a clean Omarchy install (Hyprland 0.56.2, Omarchy 4.0.0) with no
extra config layers. Verified on a 1920x1080 laptop panel.

---

## What you get

Press `SUPER + M` and a `media` workspace drops over whatever you were doing,
with Reddit, YouTube, and X already open in three equal columns. Press it again
to dismiss. The windows stay alive between visits, so the second press is
instant.

| Key | Action |
|---|---|
| `SUPER + M` | Toggle the media workspace open/closed |
| `SUPER + ALT + M` | Move the focused window into it |
| `SUPER + SHIFT + M` | Move the focused window in without following it |

`SUPER + M` was chosen because `SUPER + SHIFT + M` is already Spotify in
Omarchy's default bindings. Check yours with `omarchy menu keybindings --print`
before changing it.

---

## Files

Three files, all in `~/.config/` and `~/.local/bin/`. Nothing under
`/usr/share/omarchy/` is touched, so `omarchy update` will not overwrite any of
this.

```
~/.config/hypr/media.lua                     (new)     workspace rule + keybinds
~/.config/hypr/hyprland.lua                  (edit)    one require line
~/.config/hypr/looknfeel.lua                 (edit)    scrolling column_width
~/.local/bin/omarchy-webapp-workspace        (new)     launcher script
```

### 1. `~/.local/bin/omarchy-webapp-workspace`

The launcher. Sizes the columns, then opens each app that is not already in the
workspace.

```bash
#!/usr/bin/env bash

# omarchy:summary=Open a special workspace's web apps, sized to fit the screen
# omarchy:args=<workspace> <class=url>...
#
# Meant to be run from a special workspace's on_created_empty rule, which
# fires while that workspace is being created, so freshly mapped windows land
# in it on their own.
#
# The first argument names the workspace being opened. Each remaining argument
# pairs a window-class fragment with the URL to open there. An app already
# open in the workspace is left alone, so re-entering it never stacks up
# duplicate windows.
#
# Column width is set *before* the apps launch, not after. Hyprland bakes each
# window's width in when the window is created: changing scrolling:column_width
# later does not resize windows that already exist, and not even hiding and
# re-showing the workspace recomputes them. So the count has to be known up
# front, which it is, because the launch list is right here.

set -uo pipefail

name="${1:-}"
shift || true

if [[ -z $name ]]; then
  echo "Usage: $(basename "$0") <workspace> <class=url>..." >&2
  exit 1
fi

# Let the workspace finish coming up before counting or mapping anything.
sleep 0.2

# Only the apps that are not open in this workspace yet, as "<class>=<url>".
# The workspace name is matched loosely because Hyprland reports special
# workspaces with a "special:" prefix that is not worth hard-coding.
pending=()
for spec in "$@"; do
  # Split on the first "=" so a URL with a query string survives intact.
  class="${spec%%=*}"
  url="${spec#*=}"

  if [[ -z $class || -z $url || $class == "$url" ]]; then
    continue
  fi

  if hyprctl -j clients | jq -e --arg w "$name" --arg c "$class" \
    'any(.[]; (.workspace.name | test($w)) and (.class | test($c; "i")))' >/dev/null; then
    continue
  fi

  pending+=("$class=$url")
done

# Existing windows plus the ones about to open decide the column width, so a
# workspace already holding two apps does not drop to three narrow columns
# because a third was added.
#
# What this cannot fix: Hyprland bakes a window's width in when the window is
# created, and changing column_width later does not resize it. So if you close
# an app by hand and come back, the survivors keep the width they were created
# at, and no setting here can re-flow them. The width below is only correct for
# the windows this script creates. To re-flow after closing something, close
# the rest too and reopen; the workspace relaunches them.
existing=$(hyprctl -j clients | jq -r --arg w "$name" \
  '[.[] | select(.workspace.name | test($w))] | length')

total=$((existing + ${#pending[@]}))

# Nothing at all to show: an empty workspace with nothing to launch.
((total == 0)) && exit 0

# One window already spans the screen on its own (the layout's
# fullscreen_on_one_column), and the width is capped at 1.0.
if ((total > 1)); then
  # Round to two decimals, which is the precision the option takes, and keep it
  # inside the 0.1-1.0 range the layout allows.
  width=$(awk -v n="$total" 'BEGIN {
    w = 1.0 / n
    if (w < 0.1) w = 0.1
    if (w > 1.0) w = 1.0
    printf "%.2f", w
  }')

  # hyprctl keyword is legacy-only and does nothing under the Lua parser;
  # eval is the way to change config at runtime.
  hyprctl eval "hl.config({ scrolling = { column_width = $width } })" >/dev/null 2>&1
fi

for spec in "${pending[@]}"; do
  omarchy-launch-webapp "${spec#*=}"
  # Chromium hands the URL to the browser that is already running, which is
  # quick, but stagger the launches so they cannot race each other.
  sleep 0.4
done
```

```bash
chmod +x ~/.local/bin/omarchy-webapp-workspace
```

`~/.local/bin` is already on `PATH` in Omarchy, so the bare script name works
from the config.

### 2. `~/.config/hypr/media.lua`

The workspace rule and the keybinds. Data-driven, so adding a workspace is one
table entry.

```lua
-- Named special workspaces that open with their web apps already running.
--
-- Each entry is a special workspace (not a numbered one) so it drops over
-- whatever you were doing instead of taking a slot in the 1-10 rotation, and
-- it keeps its windows between visits, so the apps are still there the second
-- time you press the key.
--
-- The scrolling layout is what makes several apps usable at once: windows sit
-- side by side at a fixed column width and the strip scrolls, instead of
-- dwindle shrinking them all into unreadable slivers.
--
-- Column width is set globally in looknfeel.lua, not here: Hyprland 0.56
-- takes a `layout_opts` table on a workspace rule but does not apply it, so a
-- per-workspace column_width is silently ignored.

local workspaces = {
  {
    name = "media",
    label = "Media",
    -- SUPER + M, chosen because SUPER + SHIFT + M is already "Music".
    keys = "SUPER + M",
    -- Each app is a window-class fragment, matched case-insensitively against
    -- a running window's class, plus the URL to open for it. Chromium names
    -- its app windows after the host, e.g. "chrome-www.reddit.com__-Default".
    -- Add another by appending one more { "host", "url" } line.
    apps = {
      { "reddit\\.com", "https://www.reddit.com/" },
      { "youtube\\.com", "https://www.youtube.com/" },
      { "^chrome-x\\.com", "https://x.com/" },
    },
  },
}

for _, workspace in ipairs(workspaces) do
  -- Apps to launch, as "<class>=<url>" arguments for the helper script.
  local args = { workspace.name }
  for _, app in ipairs(workspace.apps) do
    args[#args + 1] = app[1] .. "=" .. app[2]
  end

  -- The special: prefix is how Hyprland addresses special workspaces in rules.
  hl.workspace_rule({
    workspace = "special:" .. workspace.name,
    layout = "scrolling",
    -- No gaps_in/gaps_out here on purpose, so the scrolling strip inherits the
    -- global gaps from looknfeel.lua. Setting them per workspace would pin
    -- this one workspace to different spacing than every other window.
    --
    -- Fires the moment the workspace is created empty, which is what pressing
    -- the key on a workspace with no apps yet does. Windows mapped from here
    -- land in this workspace because it is the active one at that moment.
    on_created_empty = "omarchy-webapp-workspace " .. table.concat(args, " "),
  })

  -- Toggle it open or closed. This is the only bind strictly required; the two
  -- below just let windows move between this workspace and the rest.
  o.bind(workspace.keys, workspace.label .. " workspace", hl.dsp.workspace.toggle_special(workspace.name))

  local key = workspace.keys:gsub("^SUPER %+ ", "")

  o.bind(
    "SUPER + ALT + " .. key,
    "Move window to " .. workspace.label,
    hl.dsp.window.move({ workspace = "special:" .. workspace.name, follow = false })
  )
  o.bind(
    "SUPER + SHIFT + " .. key,
    "Move window silently to " .. workspace.label,
    hl.dsp.window.move({ workspace = "special:" .. workspace.name, follow = false })
  )
end
```

### 3. `~/.config/hypr/hyprland.lua`

One line, after `require("hypr.looknfeel")`:

```lua
require("hypr.looknfeel")
require("hypr.media")
```

Order matters only in that user files load after Omarchy's defaults, which is
already how this file is structured.

### 4. `~/.config/hypr/looknfeel.lua`

The scrolling column width. Omarchy defaults this to `0.49`:

```lua
-- https://wiki.hypr.land/configuring/layouts/scrolling-layout/
--
-- Column width here is only the starting value. The media workspace
-- (hypr/media.lua) resizes it to 1/window-count each time it opens, so two
-- apps split the screen 50/50 and three split it three ways. It has to be set
-- globally rather than per workspace because Hyprland 0.56 accepts a
-- `layout_opts` table on a workspace rule but does not apply it.
--
-- The value is read when a window is created and never recomputed after, so
-- the script sets it before launching the apps rather than after.
hl.config({
  scrolling = {
    column_width = 0.5,
  },
})
```

This replaces the commented-out scrolling example already in the stock file.

### 5. Apply

```bash
hyprctl reload
hyprctl configerrors    # must print nothing
```

Hyprland also auto-reloads on save, but `configerrors` is the only reliable way
to know a Lua file actually parsed. An empty result is the pass condition.

---

## How the column sizing works

The script sets `column_width = 1 / window_count` **before** launching anything:

| Apps open | `column_width` set | Measured width | Screen share |
|---|---|---|---|
| 2 | 0.50 | 945px | 0.49 |
| 3 | 0.33 | 622px | 0.32 |
| 4 | 0.25 | — | — |

Measured on 1920x1080 with stock gaps (`gaps_in = 5`, `gaps_out = 10`). The
measured share is always a little under the nominal fraction because the gaps
come out of the same budget.

A single app is left alone: the layout's `fullscreen_on_one_column` already
spans the whole screen, so the script skips the width change when the total is
1.

### Why the width is set before launching

This is the part that is easy to get wrong. `column_width` is read once, when a
window is created. All of these were tested and **none of them resize an
existing window**:

- setting `column_width` while the workspace is open
- hiding and re-showing the workspace
- moving focus between columns

The only thing that works is setting the value before the windows exist. Since
the launch list is in the config, the count is always known up front, so this is
not a limitation in practice — only for windows you move in by hand.

---

## Gotchas found while building this

These cost real debugging time and are all silent failures.

### `layout_opts` on a workspace rule is ignored

The Hyprland wiki documents per-workspace layout options, and 0.56.2 accepts
the table without complaint:

```lua
hl.workspace_rule({
  workspace = "special:media",
  layout = "scrolling",
  layout_opts = { column_width = 0.33 },   -- accepted, never applied
})
```

The columns stay at the global width. A deliberately bogus key
(`this_key_does_not_exist = 1`) also produces no error, so there is no way to
tell from the config that the table is being dropped. Confirmed with a
throwaway workspace: `column_width = 0.2` still produced 0.47-wide columns.

**Set `scrolling.column_width` globally instead.**

### `hyprctl keyword` does nothing under the Lua parser

Since Hyprland 0.55, config is Lua. The legacy `hyprctl keyword` interface is
dead:

```
$ hyprctl keyword "scrolling:column_width" 0.2
keyword can't work with non-legacy parsers. Use eval.
```

It still exits 0, so a script that does not check will appear to succeed. Use:

```bash
hyprctl eval 'hl.config({ scrolling = { column_width = 0.2 } })'
```

This also invalidated an early round of testing here — a "global change had no
effect" result that was really just `keyword` silently no-opping.

### Legacy dispatcher syntax fails

`hyprctl dispatch` now evaluates Lua. Old string syntax is a parse error:

```
$ hyprctl dispatch closewindow address:0x55cb651c70e0
error: [string "return hl.dispatch(closewindow address:0x55cb6..."]:1: ')' expected near 'address'
```

Use the Lua forms:

```bash
hyprctl dispatch "hl.dsp.focus({ window = \"address:$ADDR\" })"
hyprctl dispatch 'hl.dsp.window.close()'
hyprctl dispatch 'hl.dsp.workspace.toggle_special("media")'
```

Note `hl.dsp.window.close()` with no arguments closes the *focused* window, so
focus first when cleaning up by address.

### Focusing a window in a hidden workspace can strand it

`binds.hide_special_on_workspace_change` is `true` in Omarchy's defaults.
Focusing a window on a different workspace hides the special one, and a
subsequent `window.move` can leave the window nowhere findable. Move windows
into the media workspace from inside the media workspace, or target them by
address without focusing first. This destroyed a test window during
development; the reliable cleanup is address-targeted close, above.

---

## Adding or changing apps

Edit the `apps` table in `media.lua`. One line per app: a window-class pattern
and a URL.

```lua
apps = {
  { "reddit\\.com", "https://www.reddit.com/" },
  { "youtube\\.com", "https://www.youtube.com/" },
  { "^chrome-x\\.com", "https://x.com/" },
  { "^chrome-www\\.instagram\\.com", "https://www.instagram.com/" },
},
```

The pattern is matched case-insensitively against `hyprctl clients`' `.class`
field. Chromium names its `--app=` windows after the URL's host:

| Site | Window class |
|---|---|
| `https://x.com/` | `chrome-x.com__-Default` |
| `https://www.reddit.com/` | `chrome-www.reddit.com__-Default` |
| `https://web.whatsapp.com/` | `chrome-web.whatsapp.com__-Default` |

Find the exact class for any site by opening it and running:

```bash
hyprctl clients -j | jq -r '.[] | "\(.class)  |  \(.title)"'
```

Anchor short patterns with `^`. `x.com` is a substring of many unrelated
hostnames, so `^chrome-x\.com` is much safer than `x\.com`.

The pattern only decides whether an app is *already open*. It does not have to
be a perfect match — a too-loose pattern just means that app never reopens.

After editing: `hyprctl reload`.

### Adding a second workspace

Copy the table entry. Give it a name, a free key, and its own apps:

```lua
{
  name = "chat",
  label = "Chat",
  keys = "SUPER + D",
  apps = {
    { "^chrome-discord\\.com", "https://discord.com/app" },
  },
},
```

The loop generates the rule and all three binds. There is no fixed limit on how
many named special workspaces you can define — the "~97" figure floating around
is not a real Hyprland constraint, just how many you would actually use.

---

## Behaviour notes

- **Windows persist between visits.** Toggling off hides the workspace; it does
  not close anything. The apps reload instantly on the next press.
- **No duplicates.** The script skips any app already open in the workspace, so
  hide/show cycles never stack windows.
- **Re-flowing after a manual close does not work.** If you close one app by
  hand, the survivors keep the width they were created at. Close the rest and
  reopen to get correct sizing. This is the Hyprland behaviour described above,
  not a config bug.
- **Column width is global.** It applies to any future scrolling workspace too.
  Per-workspace width does not work, so this is unavoidable.
- **`SUPER + M` must be free.** It is on a clean install, but check
  `omarchy menu keybindings --print` if you have added your own binds.

---

## Removing it

```bash
rm ~/.config/hypr/media.lua ~/.local/bin/omarchy-webapp-workspace
```

Then delete the `require("hypr.media")` line from `hyprland.lua` and the
`scrolling` block from `looknfeel.lua`, and `hyprctl reload`. Windows already
open in the workspace stay until closed; toggle it open and close them, or
leave them, as you prefer.

To keep the workspace but stop the auto-launch, empty the `apps` table — the
workspace rule and keybinds remain, and it becomes a plain scrolling workspace.
