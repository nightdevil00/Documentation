---
name: omarchy-plugin
description: >
  Expert knowledge for authoring, validating, and debugging Omarchy 4.0 shell
  plugins (Quickshell/QML bar widgets, panels, overlays, menus, services).
  REQUIRED before creating anything under ~/.config/omarchy/plugins/, editing a
  manifest.json, or debugging a bar widget that does not appear or does
  nothing. Covers the exact `schemaVersion: 1` manifest schema enforced by
  `omarchy plugin validate` (required fields, reserved omarchy.* namespace,
  safe relative entry points, no symlinks, the kind→entryPoints table), the
  `qs.Ui` / `qs.Commons` component library, plugin API injection and the
  singleton-import trap, per-widget settings via `schema`, IPC, and the
  install/enable/rescan lifecycle. Triggers: omarchy plugin, manifest.json,
  bar widget, barWidget, shell plugin, quickshell plugin, omarchy plugin
  validate, omarchy plugin add, omarchy plugin clone, plugin does not show in
  bar, Panel.qml, BarWidget.qml, moduleName, ipcTarget.
---

# Omarchy Plugin Skill

Omarchy 4.0 has no separate status-bar program. The bar, menus,
notifications, OSD, lock screen and polkit agent are all one long-running
Quickshell process (`omarchy-shell`), and **plugins are QML loaded into that
same process**. A plugin is not a script and not a separate binary.

Waybar, Walker, Mako, SwayOSD, hyprlock, hypridle, swaybg and polkit-gnome are
not part of this stack. Do not propose them.

For the CLI dispatcher, config layering and hook system, see the `omarchy`
skill. For QML/Quickshell language detail see `quickshell`.

## 0. Verified state of this machine

| Fact | Value |
| --- | --- |
| Omarchy | `4.0.0.r6713.ga85e29a-1` |
| Quickshell | `0.3.1`, run as `quickshell -n -p /usr/share/omarchy/shell` |
| Shell root type | `ShellRoot` (`shell/shell.qml`) |
| User plugin dir | `~/.config/omarchy/plugins/<id>/` |
| First-party plugins | `$OMARCHY_PATH/shell/plugins/` |
| Manifest schema | `schemaVersion: 1` — no other version is accepted |
| Live plugins here | `mihai.spotlight`, `pick.screenshot`, `bt.codecs`, `mihai.llama`, `mihai.picker`, `mihai.renderer`, `mihai.ytmusic`, `yt-pony`, `omapony`, plus vendored `nightdevil00.custom-settings` |

## 1. Layout

```
~/.config/omarchy/plugins/<plugin-id>/
    manifest.json      REQUIRED — schemaVersion 1
    <entry point>.qml  one per declared kind
    preview.png        optional, shown in plugin menus
    README.md          optional
    LICENSE            optional
    Model.js           optional — keep logic out of QML
```

Plugin folder name, `manifest.json` `id`, and the directory name under
`~/.config/omarchy/plugins/` should match. Mismatches confuse `plugin list`
output and removal.

## 2. The manifest schema (exact)

`omarchy plugin validate` mirrors the checks in
`shell/services/PluginRegistry.qml`, so a manifest that passes validation is
one the shell will actually load. **Run it before you claim a plugin works:**

```bash
omarchy plugin validate ~/.config/omarchy/plugins/<plugin-id>
```

### Required fields

| Field | Rule |
| --- | --- |
| `schemaVersion` | JSON **number** `1`. `"1"` (string) is rejected. |
| `id` | non-empty, `^[A-Za-z0-9][A-Za-z0-9._-]*$`, no `..`, **must not** start with `omarchy.` |
| `name` | human label |
| `version` | e.g. `"1.0.0"` |
| `kinds` | non-empty array |
| `entryPoints` | object; every value a **relative** path to a file that exists |

`omarchy.*` is a **reserved namespace** for first-party plugins. Validation
hard-fails on it. Use your own prefix (`mihai.`, `local.`, `acme.`).

### The kind → entryPoints table

Declaring a kind without its matching entry point is the classic silent
failure: the plugin installs, enables, and does nothing. Validation refuses it.

| `kinds` entry | required key in `entryPoints` |
| --- | --- |
| `bar` | `entryPoints.bar` |
| `bar-widget` | `entryPoints.barWidget` |
| `menu` | `entryPoints.menu` |
| `overlay` | `entryPoints.overlay` |
| `panel` | `entryPoints.panel` |
| `service` | `entryPoints.service` |

A plugin may declare several kinds (e.g. `["bar-widget", "panel"]`) and supply
several entry points — that is how one plugin contributes a bar icon *and* a
full settings panel.

### Entry point path safety

Every entry point value must:

- be **relative** (no leading `/`)
- contain **no `..`** segment
- contain no newline
- point at a file that **exists** in the plugin folder

### Symlinks are forbidden

Any symlink anywhere inside the plugin folder fails validation (`.git` is
exempt, since installed plugins are git checkouts). This is a security control:
a symlink could point a copied plugin at arbitrary files on disk. Never
work around it with symlinks — copy the file.

### Full bar-widget manifest

```json
{
  "schemaVersion": 1,
  "id": "mihai.renderer",
  "name": "Renderer",
  "version": "1.0.0",
  "author": "mihai",
  "license": "MIT",
  "description": "Shows which GPU renders the desktop and lets you pick a different one",
  "kinds": ["bar-widget"],
  "activation": "on-demand",
  "entryPoints": {
    "barWidget": "Panel.qml"
  },
  "barWidget": {
    "displayName": "Renderer",
    "description": "Shows which GPU renders the desktop and lets you pick a different one",
    "category": "System",
    "allowMultiple": false,
    "defaultSection": "right",
    "aliases": ["gpu", "graphics"],
    "defaults": { "refreshIntervalSec": 60 },
    "schema": [
      {
        "key": "refreshIntervalSec",
        "type": "integer",
        "label": "Refresh interval (seconds)",
        "description": "How often to re-read GPU state",
        "min": 15,
        "max": 3600,
        "step": 15,
        "defaultValue": 60
      },
      {
        "key": "showTokens",
        "type": "boolean",
        "label": "Show today's tokens in the bar",
        "defaultValue": true
      }
    ]
  }
}
```

Notes on the optional parts:

- `activation: "on-demand"` — observed on heavier widgets; do work when opened
  rather than continuously.
- `barWidget.defaultSection` — must be exactly `left`, `center` or `right`;
  anything else fails validation.
- `barWidget.allowMultiple` — `false` keeps a single instance in the bar.
- `barWidget.aliases` — extra search terms for `omarchy menu plugin`.
- `barWidget.category` — groups it in plugin menus (`System`, `Audio`, `AI`,
  `Compositor`, `Custom`, …).
- `defaults` + `schema` generate a settings UI. Values arrive in the widget as
  `settings.<key>`. Use `defaultValue` (not `default`) in schema entries — this
  is the key real manifests use.
- `icon` appears in one local plugin but is **not** part of the enforced
  schema; treat it as optional and unverified.

### Multi-kind manifest

```json
{
  "schemaVersion": 1,
  "id": "nightdevil00.custom-settings",
  "name": "Omarchy Settings",
  "version": "1.0.0",
  "author": "nightdevil00",
  "license": "MIT",
  "description": "Settings hub for Hyprland, the bar, idle and updates",
  "kinds": ["bar-widget", "panel"],
  "entryPoints": {
    "barWidget": "BarWidget.qml",
    "panel": "SettingsPanel.qml"
  },
  "barWidget": {
    "displayName": "Omarchy Settings",
    "category": "System",
    "allowMultiple": false,
    "defaultSection": "center"
  }
}
```

`omarchy.background` uses the `service` kind with
`"entryPoints": { "service": "Background.qml" }` and **no** kind-specific
block — headless plugins have no bar presence.

## 3. QML: imports and the singleton trap

Available module roots (root-relative, so they resolve from any plugin folder):

| Import | Provides |
| --- | --- |
| `qs.Commons` | `Color` (singleton: `Color.accent`, `Color.foreground`, …), `Style`, `ShellIpc`, `IpcRegistry`, `Util`, `Border`, `BorderGeometry.js` |
| `qs.Ui` | `Panel`, `BarWidget`, `BarIconButton`, `OverlayWindow`, `Button`, `ConfirmDialog`, `Dropdown`, `NumberField`, `PanelHero`, `PanelSectionHeader`, … |
| `Quickshell`, `Quickshell.Io`, `Quickshell.Hyprland`, … | toolkit core, IO, compositor bindings |

**The most important rule in this file.** Do *not* re-import shared services as
singletons inside your plugin. `shell.qml` injects them as properties because
"relative-path imports do not share singleton state, which silently leaves
consumers with their own empty copies." A widget that imports its own copy of a
service sees empty data and no error — the single hardest bug to diagnose in
this stack.

Use the injected properties (`bar`, `pluginRegistry`, `barWidgetRegistry`,
`appLibrary`, …) and the injected API objects instead.

### Bar widget skeleton

Root it in `Panel`, which handles the bar icon + popout panel pair:

```qml
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

Panel {
  id: root
  moduleName: "mihai.renderer"
  ipcTarget: "mihai.renderer"

  // Provided by the shell. `bar` is null when the widget is not in the bar.
  readonly property color hoverFill: bar
    ? Style.hoverFillFor(bar.barForeground, Color.accent)
    : "transparent"

  // Generated from the manifest's defaults + schema.
  readonly property int interval: settings.refreshIntervalSec || 60

  readonly property string barText: currentGpu || "…"

  Process {
    id: probe
    running: true
    command: ["sh", "-c", "lspci | grep -m1 'VGA\\|3D'"]
    stdout: StdioCollector { onStreamFinished: root.currentGpu = this.text.trim() }
  }
}
```

`Panel` properties worth knowing: `bar` (nullable `QtObject`),
`moduleName` (**required** — the settings/IPC identity), `settings` (object
built from the manifest `schema`), `ipcTarget`, `manageIpc`, `controller`,
`opened`, `popoutSwitching`, `barForeground`.

Guard every `bar.`-rooted expression — `bar` is null outside the bar, so
`bar.barForeground` unguarded throws on a null dereference and the widget
silently disappears.

Keep logic in a sibling `Model.js` and import it
(`import "Model.js" as Model`). A `Panel.qml` over ~300 lines is a sign the
logic belongs in the JS module.

## 4. Installing and enabling

```bash
omarchy plugin validate ~/.config/omarchy/plugins/<id>   # FIRST
omarchy plugin list [--json]                              # is it discovered?
omarchy plugin enable <id> [left|center|right]
omarchy plugin disable <id>
omarchy plugin add <git-url> [--enable] [--yes]
omarchy plugin clone omarchy.<id> [--edit]   # vendor a built-in to customize
omarchy plugin remove <id> [--yes]
omarchy plugin update <id> [--yes]           # git-managed plugins only
omarchy plugin catalog
omarchy menu plugin                          # TUI
```

`omarchy shell shell rescanPlugins` re-reads manifests in place — cheap, keeps
windows and menus alive. Use it while iterating. `omarchy restart shell`
restarts the whole process (bar blinks, menus close); use it after changing
`shell.json` or when the rescan clearly did not pick up a structural change.

**A plugin that is enabled but absent from `bar.layout` in
`~/.config/omarchy/shell.json` renders nothing.** Enabling is not placing.
Bar entries are objects:

```json
"right": [
  { "id": "omarchy.tray" },
  { "id": "mihai.renderer" },
  { "id": "omarchy.audio" }
]
```

Per-entry options are allowed, e.g.
`{ "id": "omarchy.clock", "format": "ddd d MMM h:mm AP" }`.

`omarchy plugin list --json` returns an array whose entries carry `id`, `name`,
`kinds`, `enabled`, `active`, `canDisable`, `firstParty` and `clonedFrom`.
`clonedFrom` is how a vendored copy identifies its first-party original (e.g.
`io.github.prostratepossum.starwatch-lock` reports
`clonedFrom: "omarchy.lock"`) — the quickest way to tell a clone from an
unrelated plugin with a similar name.

## 5. Troubleshooting

Work in this order:

```bash
# 1. Manifest valid? (checks schema, reserved id, paths, symlinks, kind table)
omarchy plugin validate ~/.config/omarchy/plugins/<id>

# 2. Discovered by the shell?
omarchy plugin list --json | jq '.[] | select(.id=="<id>")'

# 3. Placed in the bar?
grep -n '"<id>"' ~/.config/omarchy/shell.json

# 4. Enabled, or listed in disabledPlugins?
jq '.disabledPlugins' ~/.config/omarchy/shell.json

# 5. QML errors from the shell process
journalctl --user -b | grep -iE 'quickshell|qml|<id>'
omarchy shell shell ping
omarchy shell shell rescanPlugins
```

Symptom → cause table:

| Symptom | Cause |
| --- | --- |
| Not in `plugin list` | missing/invalid `manifest.json`, wrong folder name, `schemaVersion` not numeric `1` |
| Validation: reserved namespace | `id` starts with `omarchy.` — rename it |
| Validation: kind requires entry point | declared a kind with no matching `entryPoints` key |
| Validation: entry point not found | relative path wrong, or file not saved |
| Validation: symlinks not allowed | replace a symlink with a real copy |
| Installs but shows nothing | enabled but missing from `bar.layout` |
| Widget appears then vanishes | unhandled null `bar.…` dereference, or a QML error thrown during construction |
| Widget visible, data always empty | re-imported a service as a singleton instead of using the injected instance (§3) |
| Settings ignored | `schema` uses `default` instead of `defaultValue`, or the key does not match `settings.<key>` |
| Duplicate instances | `allowMultiple` not `false` and the id was placed twice |

Read the shell's own errors rather than guessing:

```bash
journalctl --user -b -p 3 --since "10 min ago"
```

## 6. Safety rules

- **Plugins are unsandboxed QML in the user's session.** Never generate code
  that requires `sudo`, prompts for input, reads secrets, writes outside the
  user's home, or shells out to untrusted input.
- **Never shell out with interpolated user data.** Use
  `Process { command: ["prog", arg] }` with an argument array, not a
  `sh -c` string built from variables.
- **Validate before claiming success:**
  `omarchy plugin validate <dir>` plus a `rescanPlugins`, then actually look at
  the bar.
- **Do not modify first-party plugins in `/usr/share/omarchy/shell/plugins/`.**
  That tree is package-owned. Use `omarchy plugin clone <id> --edit` to vendor
  a copy into `~/.config/omarchy/plugins/` and edit that.
- **Do not reuse the `omarchy.*` id namespace.**
- **Do not disable stock `omarchy.*` plugins** without telling the user which
  visible feature disappears. This machine deliberately disables
  `omarchy.background` and `omarchy.lock`.
- **Keep the process cheap.** A `Timer` running every second in a permanent
  bar widget is a battery bug; use the manifest `schema` to make the interval
  configurable and default it high.
- **Prefer a `service` kind for headless logic** and let a thin `bar-widget`
  display it, rather than polling from the widget itself.

## Example requests

- "Add a bar widget that shows X" → §2 manifest + §3 skeleton + §4 placement.
- "My plugin doesn't show up" → §5 in order.
- "Clone the clock widget and tweak it" → `omarchy plugin clone omarchy.clock --edit`.
- "Give my plugin a settings dropdown" → `defaults` + `schema` in §2.
- "Is this manifest valid?" → `omarchy plugin validate`, quote the exact error.