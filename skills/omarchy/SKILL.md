---
name: omarchy
description: >
  Expert knowledge for administering this Omarchy desktop — the `omarchy` CLI,
  the Quickshell-based shell, config layering, themes, plugins, hooks, toggles,
  updates, and system lifecycle. REQUIRED before running any `omarchy ...`
  command, editing anything under ~/.config/omarchy/, or diagnosing bar/menu/
  notification/lock/theme/install/update problems. Covers the CLI dispatcher
  model (omarchy-<group>-<name> helpers -> `omarchy <group> <name>` routes),
  `omarchy commands` discovery, config precedence (shipped defaults ->
  ~/.config), shell.json and shell.toml, the plugin manifest schema, theme
  colors.toml + `*.tpl` templating, the hook system, toggle state in
  ~/.local/state/omarchy, uwsm session management, and the refresh/restart/
  update lifecycle. Triggers: omarchy, omarchy CLI, omarchy update, omarchy
  theme set, omarchy plugin, shell.json, shell.toml, colors.toml, omarchy hook,
  omarchy toggle, omarchy refresh, omarchy restart, omarchy install, omarchy
  remove, omarchy hw, bar not showing, menu, lock screen, screensaver.
---

# Omarchy Skill

Omarchy is an Arch-based opinionated desktop: Hyprland + a Quickshell shell
(bar, menus, notifications, OSD, lock, polkit agent) + SDDM/uwsm session
management. Almost every "the desktop looks wrong" report is a config-layer,
theme, plugin, or hook problem — not a compositor problem.

This skill is the **map of the system**. For depth in one area, use the
specialist skills: `hyprland`, `quickshell`, `omarchy-plugin`, `omarchy-theme`,
`sddm`, `systemd`, `arch`, `wayland-environment`.

## 0. Verified state of this machine

Checked against this installation. Re-verify with the commands in §12 if the
system has been updated since.

| Layer | Fact |
| --- | --- |
| Omarchy | `4.0.0.r6713.ga85e29a-1` (`omarchy version`) |
| Root | `/usr/share/omarchy/` (`$OMARCHY_PATH`), helpers in `bin/` |
| Compositor | Hyprland `0.56.2`, **Lua** config (`~/.config/hypr/*.lua`) |
| Shell | Quickshell `0.3.1`, one long-running `omarchy-shell` process |
| Shell entry | `quickshell -n -p /usr/share/omarchy/shell`, root type `ShellRoot` |
| Display manager | SDDM `0.21.0`, Wayland greeter via Hyprland, `DisplayServer=wayland` |
| Session manager | uwsm — sessions start as `uwsm start -e -D Hyprland hyprland.desktop` |
| Shell config | `~/.config/omarchy/shell.json` + `~/.config/omarchy/shell.toml` |
| Themes | `~/.config/omarchy/themes/<slug>/`, shipped in `/usr/share/omarchy/themes/` |
| Plugins | `~/.config/omarchy/plugins/<id>/`, each with `manifest.json` |
| Hooks | `~/.config/omarchy/hooks/<event>` and `<event>.d/NN-name` |
| Runtime state | `~/.local/state/omarchy/` (current theme, toggles) |
| Report tool | `omarchy-debug --no-sudo --print` (standalone, **not** a route) |

Hardware, from `omarchy-debug`:

| Layer | Fact |
| --- | --- |
| Machine | Lenovo ThinkBook 15p (20V3), laptop |
| CPU | Intel Core i7-10750H (Comet Lake, 6c/12t) |
| Kernel | `7.2.5-4-omarchy`, `x86_64`, gcc 16.2.1 |
| Root fs | **btrfs** on `/dev/mapper/root`, `subvol=@`, `resume_offset` set |
| Battery | `BAT0`, Li-poly 54.4 Wh, 57 cycles |
| Firmware | UEFI, Lenovo `F6CN30WW` (2023-09-19) |

Consequences worth remembering: the root filesystem is btrfs (so
`omarchy snapshot` uses snapper, and "restore the whole system" is
`omarchy snapshot restore`, not an fsck story), the kernel carries an
`-omarchy` suffix (so `pacman -S linux` is not what is running), and this is a
laptop (so `omarchy hw laptop` is true and clamshell/suspend behaviour matters).

**Not installed here** (skills exist as portable reference only): Niri,
Noctalia, Caelestia, fish, Rust toolchain. Do not assume them.

## 1. Core model: the CLI is a dispatcher

`omarchy` is not a monolithic program. It is a front-end over
`/usr/share/omarchy/bin/omarchy-*` helpers (**476** files, **392** documented
routes). Learn the derivation rule and you can read any command's source
instead of guessing.

**Route derivation.** Strip the `omarchy-` prefix and turn remaining hyphens
into spaces:

```
omarchy-theme-set        -> omarchy theme set
omarchy-restart-shell    -> omarchy restart shell
omarchy-snapshot         -> omarchy snapshot
```

So the binary name tells you the route. To find the binary for a route, join
the words with hyphens: `omarchy hw nvidia display` -> `omarchy-hw-nvidia-display`.

**Metadata override.** A helper's leading comments can redefine its route and
docs. Read the top of any helper before trusting the filename derivation:

```bash
#!/bin/bash
# omarchy:group=theme
# omarchy:name=set
# omarchy:summary=Apply an Omarchy theme
# omarchy:args=<theme-name>
# omarchy:examples=omarchy theme list
# omarchy:requires-sudo=true     # only ever "true" or omitted
# omarchy:hidden=true            # only ever "true" or omitted
```

Valid keys: `group`, `name`, `summary`, `args`, `examples`, `alias`/`aliases`
(`|`-separated), `requires-sudo`, `hidden`. Anything else is ignored.

## 2. Discovery — never guess a command

```bash
omarchy                      # group list + common commands
omarchy commands             # full command table
omarchy commands --json      # machine-readable (jq-friendly)
omarchy commands --markdown  # markdown table
omarchy commands --check     # validate metadata + route collisions
omarchy <group>              # one group's commands
omarchy <group> <cmd> --help # usage, args, examples, aliases, binary
omarchy <group> <cmd> --help --json   # same, machine-readable
```

An unknown route prints `Unknown Omarchy command: ...` plus a
`Did you mean:` suggestion. Treat that as authoritative: the command does not
exist in this version.

### Aliases are hidden from the command list

`omarchy commands` prints routes, **not aliases**. A documented alias still
works but will not appear in `--json`, so a route lookup can wrongly suggest a
command is missing. Verify with `--help` before concluding anything is absent:

| Alias | Real route |
| --- | --- |
| `omarchy screenshot` | `omarchy capture screenshot [smart\|region\|windows\|fullscreen\|scroll] [copy\|save]` |
| `omarchy screenrecord` | `omarchy capture screenrecording [--fullscreen] [--stop-recording] …` |
| `omarchy plugin install` | `omarchy plugin add` |

`omarchy bar` is a group whose real subcommands are `use`, `reset`,
`defaults`, `position`, `transparent`, `put`, `move`, `set` — e.g.
`omarchy bar move omarchy.clock --section right`. It does not appear as a
leaf route either.

### Topic guides

Depth lives beside this file — read the one you need, not all of them:

| File | Covers |
| --- | --- |
| `capture.md` | screenshots, screen recording, webcam, sharing |
| `hooks.md` | hook directory layout, update-related hook ordering |
| `plugins.md` | bar layout, cloning built-in widgets, idle and lock |
| `theming.md` | theme commands, authoring, backgrounds, fonts |
| `hyprland.md` | Omarchy's Hyprland Lua config, keybindings, monitors, rules |
| `contributing.md` | filing a good bug report, submitting a PR |

The `omarchy-plugin` and `omarchy-theme` skills in this repo go deeper on
manifest authoring and the `colors.toml` resolver respectively.

### Commands that do NOT exist (commonly hallucinated)

Verified absent on `4.0.0.r6713`. Do not emit them:

- `omarchy debug` — **wrong invocation form.** The report tool is a *standalone*
  binary, `/usr/bin/omarchy-debug`, and is **not** routed through the
  dispatcher. Call it as `omarchy-debug --no-sudo --print` (§2). Note that
  Omarchy's own bundled skill gets this wrong — trust the binary, not the docs.
- `omarchy restart shell --now`, `omarchy shell reload`, `omarchy doctor`.
- `omarchy config ...` — config lives in files; `refresh` resets it.

Real crash/diagnostic surface:

```bash
omarchy-debug --no-sudo --print     # full report to stdout (1455 lines here)
omarchy-debug --no-sudo             # same, but may prompt for upload/save
omarchy-debug-idle                  # idle-specific diagnostics
omarchy agent crash <pid> [comm] [exe] [signal]  # hand a crash to a coding agent
omarchy crash mute <program>                     # silence one program's crash popup
omarchy crash watch
omarchy toggle crash capture
omarchy update analyze logs                      # known failure conditions
omarchy launch about                            # fastfetch TUI
omarchy system stats
```

`omarchy-debug` already redacts serials (`<superuser required>`,
`<filter>`), but **hostname, kernel cmdline and battery details are still in
plain text** — skim before posting. `--no-sudo` keeps it from hanging on a
password prompt in scripts; `--print` writes to stdout instead of offering an
interactive upload.

## 3. Config layering — the single most important concept

Omarchy ships defaults and copies/symlinks them into place. When a config
"isn't taking effect", the cause is almost always that you edited the shipped
copy, or a refresh overwrote your copy.

```
/usr/share/omarchy/config/<app>/<file>    shipped default (do not edit)
              ↓  omarchy refresh config   (copies, backs up your version)
~/.config/<app>/<file>                     your live copy (edit this)
```

```bash
omarchy refresh config      # copy a shipped user config into ~/.config (backs up yours)
```

`omarchy refresh config` with no argument resets the whole user config tree and
**overwrites your versions after backing them up**. Before running any
`omarchy refresh <app>`, tell the user what will be overwritten. The
per-app refreshes are: `applications`, `chromium`, `config`, `herdr`,
`hyprland`, `hyprsunset`, `limine`, `pacman`, `plymouth`, `sddm`, `shell`,
`tmux`. Note `refresh hyprland` overwrites **all** of `~/.config/hypr/*.lua`,
and `refresh pacman` rewrites `/etc/pacman` **and updates all packages**.

Also note `/usr/share/omarchy/etc-overrides/` — files there are dropped into
`/etc` (`os-release`, `nsswitch.conf`, `dot.bashrc`, plymouth, CUPS, faillock).
That is how Omarchy identifies itself as a distro.

## 4. The shell (`omarchy-shell`)

One long-running Quickshell process provides bar, menus, notifications, OSD,
lock, and the polkit agent. Waybar, Walker, Mako, SwayOSD, hyprlock, hypridle,
swaybg and polkit-gnome are **not** in the stack — if you suggest them, you are
working from a pre-4.0 mental model.

Entry point `shell/shell.qml` is a `ShellRoot`. Plugins are sibling directories
under `shell/plugins/`, loaded into the same process. `$OMARCHY_PATH` (set by
the uwsm session environment) is the single source of truth for the checkout.

### shell.json precedence

```
builtinShellConfig        bundled fallback inside shell.qml
        ↓
$OMARCHY_PATH/config/omarchy/shell.json    shipped defaults
        ↓  merged
~/.config/omarchy/shell.json               your config (wins)
```

`omarchy refresh shell` resets `shell.json` to defaults.

```jsonc
{
  "version": 1,
  "idle": { "screensaver": 150, "lock": 300 },
  "bar": {
    "position": "top",
    "transparent": false,
    "centerAnchor": "omarchy.clock",
    "layout": {
      "left":   [ { "id": "omarchy.menu" }, { "id": "omarchy.workspaces" } ],
      "center": [ { "id": "omarchy.clock", "format": "ddd d MMM h:mm AP" } ],
      "right":  [ { "id": "omarchy.tray" }, { "id": "omarchy.audio" } ]
    }
  },
  "plugins": [ { "id": "mihai.spotlight" } ],
  "disabledPlugins": [ "omarchy.background" ]
}
```

Bar items are `{"id": "<plugin-id>"}` objects, optionally with per-item options
(`format`, `formatAlt`, `verticalFormat`). A widget that is missing from all
three lists is not rendered — that is the usual cause of "my widget vanished".

### shell.toml

Machine-level shell overrides that merge **over the active theme** and survive
theme switching. On this machine it holds only font sizing:

```toml
[font]
base-size = 11
```

### Shell IPC

```bash
omarchy shell [-q] <target> <method> [args...]
omarchy shell shell ping
omarchy shell shell rescanPlugins     # reload plugin registry
```

`omarchy shell config` is a **sourceable helper library** for editing
`shell.json` — do not execute it expecting output.

Reload vs restart: `rescanPlugins` re-reads manifests (cheap, keeps windows);
`omarchy restart shell` restarts the whole process (blinks the bar, closes
menus). Prefer the cheap one while iterating.

## 5. Themes

A theme is a **directory** of `colors.toml` + `icons.theme` + per-app config
files. There is no `theme.json` — do not invent one.

```bash
omarchy theme list        # available
omarchy theme set <slug>  # apply
omarchy theme current     # show current
omarchy theme dir         # directory holding the theme (prefers user copy)
omarchy theme install <git-url> / remove / update / extras
omarchy theme refresh     # re-render current theme from templates
omarchy theme switcher    # TUI
omarchy theme bg set|next|current|install|cache   # background image/video
```

`~/.config/omarchy/themes/<slug>/` overrides `/usr/share/omarchy/themes/<slug>/`.
Full authoring guide — including the 26 `colors.toml` keys and the `{{ }}`
templating system — is in the `omarchy-theme` skill.

### Theme state on disk

```
~/.local/state/omarchy/current/theme.name          # slug of active theme
~/.local/state/omarchy/current/theme/              # STAGED, applied copy
    colors.toml icons.theme backgrounds/ alacritty.toml neovim.lua ...
~/.local/state/omarchy/current/next-theme/         # transient during a switch
```

`colors.toml` under `current/theme/` is the source of truth for hooks and
templates at runtime — read it there when debugging live colors, not from the
theme source directory.

## 6. Plugins

Plugins are QML loaded into the shell process from
`~/.config/omarchy/plugins/<id>/`, each with a `manifest.json`
(`schemaVersion: 1`). Bar widgets are the common kind.

```bash
omarchy plugin list [--json]          # discovered plugins
omarchy plugin add <git-url> [--enable] [--yes]
omarchy plugin clone <source-id> [--edit]   # vendor a built-in into your config
omarchy plugin enable <id> [placement]
omarchy plugin disable <id>
omarchy plugin remove [id] [--yes]
omarchy plugin update [id] [--yes]
omarchy plugin validate <folder>      # check manifest against schema — USE THIS
omarchy plugin catalog
omarchy menu plugin                    # TUI for enable/disable/clone/remove
```

Authoring, the manifest schema, and QML service-injection rules are in the
`omarchy-plugin` skill.

## 7. Hooks

Hooks let you run your own code when Omarchy does something. Two forms, both in
`~/.config/omarchy/hooks/`:

```
~/.config/omarchy/hooks/<event>          single script
~/.config/omarchy/hooks/<event>.d/NN-name  ordered set, NN controls order
```

```bash
omarchy hook [name] [args...]             # run a hook by hand
omarchy hook install <type> <file>        # install into hooks/<type>.d/
```

Shipped hook events (each has a `.d/` in `/usr/share/omarchy/config/omarchy/hooks/`):
`battery-low`, `font-set`, `post-boot`, `post-update`, `pre-refresh-pacman`,
`theme-set`. Theme slug arrives as `$1` on `theme-set`.

A minimal hook — note the `set -u`, the early exit when the environment is not
there, and never blocking the caller:

```bash
#!/bin/bash
# ~/.config/omarchy/hooks/theme-set.d/50-mytheme-notify
# omarchy:summary=Announce the active theme
set -u

THEME_NAME="${1:-}"
[[ -n $THEME_NAME ]] || exit 0
notify-send "Theme: $THEME_NAME" || true
```

```bash
chmod +x ~/.config/omarchy/hooks/theme-set.d/50-mytheme-notify
omarchy hook install theme-set ~/.config/omarchy/hooks/theme-set.d/50-mytheme-notify
```

Rules: executable bit required; must not prompt; must not `sudo`; must exit 0
on anything unexpected. Hooks run inside `omarchy theme set`, so a slow or
hanging hook freezes theme switching.

## 8. Toggles and runtime state

Feature toggles are flag files under `~/.local/state/omarchy/toggles/`, so
they survive reboots without touching config files.

```bash
omarchy toggle                    # list
omarchy toggle animations         # toggle
omarchy toggle enabled <name>     # exit 0 if the flag file exists
```

Available: `animations`, `bar`, `crash capture`, `fullscreen desktop`,
`hybrid gpu`, `idle`, `nightlight`, `notification silencing`, `screensaver`,
`suspend`, `theme sync`, `touchpad`, `touchscreen`.

## 9. Hardware detection

`omarchy hw ...` predicates exist so configs and hooks can branch on hardware
instead of guessing. Use them; do not sniff `/sys` yourself.

```bash
omarchy hw match "<substring>"   # case-insensitive match on DMI product name/family
omarchy hw nvidia                # has NVIDIA GPU
omarchy hw nvidia display        # NVIDIA drives the display (not hybrid iGPU)
omarchy hw nvidia gsp            # NVIDIA with GSP firmware (Turing+)
omarchy hw hybrid gpu            # active hybrid GPU config
omarchy hw intel / intel ptl     # CPU / Intel Panther Lake GPU
omarchy hw laptop / vm           # laptop chassis / virtual machine
omarchy hw vulkan                # Vulkan available
omarchy hw webcam / touchscreen  # presence
omarchy hw display               # print the backlight device name
omarchy hw touchpad              # print the touchpad device name
omarchy hw external monitors     # true when an external monitor is connected
```

These return exit codes, not just text — use them in `if` conditions.

## 10. Packages, updates, and the update lifecycle

```bash
omarchy update                # Omarchy + system packages (the normal one)
omarchy update available      # check without installing
omarchy update confirm        # same, but prompts first
omarchy update system pkgs    # pacman packages only
omarchy update aur pkgs       # AUR packages only
omarchy update orphan pkgs    # review + remove orphans
omarchy update pkg prune      # drop superseded versions from the cache
omarchy update keyring        # ensure omarchy/arch keyrings
omarchy update firmware       # fwupd
omarchy update mise           # mise-managed tools
omarchy update time           # restart time sync
omarchy update restart        # prompt for pending reboot/service restarts
omarchy update analyze logs   # check update log for known failures
omarchy update dev            # update a dev checkout
```

Package presence helpers (exit-code predicates, useful in hooks and scripts):

```bash
omarchy pkg missing <pkgs...>   # true if any missing
omarchy pkg present <pkgs...>   # true if all present
omarchy pkg add <pkgs...>       # install if missing
omarchy pkg drop <pkgs...>      # remove if present
omarchy pkg install             # fuzzy TUI for Arch/OPR packages
omarchy pkg remove              # fuzzy TUI to remove installed packages
omarchy pkg aur accessible      # is the AUR reachable
omarchy pkg aur add <pkgs...>   # install from AUR if missing
```

**Arch discipline that applies here:** never run a bare
`pacman -Sy <pkg>` — a partial upgrade desynchronises the database and breaks
the system. Always full `omarchy update` / `pacman -Syu`. See the `arch`
skill.

`omarchy install ...` / `omarchy remove ...` (40 and 30 commands) manage
Omarchy's optional software bundles, not arbitrary packages. Use `omarchy pkg`
for packages.

## 11. Session, power, and app lifecycle

```bash
omarchy system lock          # lock + blank displays
omarchy system logout        # close windows, then log out
omarchy system reboot        # close windows, then reboot
omarchy system shutdown
omarchy system wake          # wake displays after idle
omarchy system stats         # CPU/memory for the shell

omarchy restart app <name>   # kill and relaunch via uwsm
omarchy restart audio        # recover stuck USB audio
omarchy restart bluetooth / wifi / trackpad / xcompose
omarchy restart shell        # restart the shell process
omarchy restart hyprctl      # reload Hyprland config
omarchy restart terminal     # reload terminal configs
omarchy restart opencode / btop / helix / tmux / herdr / hyprsunset

omarchy snapshot <create|restore>   # system snapshots (snapper)
omarchy launch <app>         # launchers (22 of them)
omarchy menu ...             # clipboard, emoji, file, input, select, keybindings
```

`omarchy restart hyprctl` is the theme-switch path for Hyprland;
`omarchy restart btop` / `omarchy restart opencode` reload those app configs
after a theme change. Run the specific one, not all of them.

## 12. Troubleshooting workflow

Work outward from the layer. Do not jump to reinstalling.

```bash
# 0. What version and channel am I on?
omarchy version && omarchy version channel && omarchy version pkgs

# 0b. One-shot full report (the real "omarchy debug"):
omarchy-debug --no-sudo --print

# 1. Shell: is it even running, and did it load my config?
pgrep -af quickshell
omarchy restart shell

# 2. Config: am I editing the file that is actually used?
ls -l ~/.config/omarchy/shell.json ~/.config/omarchy/shell.toml
omarchy theme current && omarchy theme dir

# 3. Plugins: what does the registry think exists, and is the manifest valid?
omarchy plugin list --json
omarchy plugin validate ~/.config/omarchy/plugins/<id>

# 4. Theme: are the live colors what I expect?
cat ~/.local/state/omarchy/current/theme/colors.toml

# 5. Hooks: is my hook failing and blocking the caller?
omarchy hook theme-set <slug>

# 6. Compositor / session / system layers (see the specialist skills)
hyprctl configerrors
journalctl --user -b -p 3
journalctl -b -p 3
```

Frequent causes, in the order they actually happen:

1. **Edited the shipped copy** under `/usr/share/omarchy/...` instead of
   `~/.config/...`.
2. **Widget not in `shell.json`** — a plugin that is enabled but absent from
   `bar.layout` renders nothing.
3. **Stale shell process** after a config edit — needs `restart shell`, not a
   rescan, when you changed `shell.json` itself.
4. **A hook hanging or exiting non-zero** inside `theme set`.
5. **Partial upgrade** from a bare `pacman -Sy` — see §10.
6. **A plugin QML error** taking down the shell — check
   `journalctl --user -b | grep -i quickshell`, then `omarchy plugin disable`.

## 13. Safety rules

- **Read before writing.** Show the user the current file and the proposed
  change before editing anything in `~/.config/omarchy/`.
- **`omarchy refresh <app>` overwrites user config.** Always warn first, and
  note that it backs up. `refresh pacman` additionally updates all packages.
- **`omarchy refresh config` with no argument resets the whole user tree.**
- **Never hand-edit `/usr/share/omarchy/`** — it is package-owned and will be
  overwritten on update. Use `~/.config/` overrides or a hook.
- **Prefer `omarchy <group> <cmd>` over the raw helper binary.** The dispatcher
  handles sudo prompting, metadata, and route resolution; calling
  `/usr/share/omarchy/bin/omarchy-theme-set` directly skips that.
- **Do not run `omarchy update` unprompted.** It updates the whole system and
  may require a reboot. Offer `omarchy update available` for a read-only check.
- **Never `sudo` a command that has a non-sudo route.** Check
  `omarchy <route> --help` for `requires-sudo`.
- **Hooks must never prompt, block, or escalate.**
- **Do not remove or disable stock plugins** (`omarchy.*`) without telling the
  user which visible feature disappears. This machine already disables
  `omarchy.background` and `omarchy.lock` deliberately.

## 14. Worked example: a widget disappeared after a theme change

1. `omarchy theme current` — theme did change.
2. `omarchy plugin list --json | jq` — is the plugin still discovered?
3. `omarchy plugin validate ~/.config/omarchy/plugins/<id>` — manifest valid?
4. `grep -A5 '"plugins"' ~/.config/omarchy/shell.json` — is its `id` listed?
5. `grep '"id": "<id>"' ~/.config/omarchy/shell.json` — is it still in
   `bar.layout`? A theme switch regenerates theme-derived config but should
   not touch `bar.layout`; if it vanished, a `refresh shell` or a bad merge did.
6. `omarchy restart shell`, then re-check.

## Example requests

- "The bar is gone" → §12 steps 1-3, `omarchy toggle bar`, `omarchy restart shell`.
- "Add a widget to my bar" → `omarchy-plugin` skill + `shell.json` `bar.layout`.
- "Make a theme" → `omarchy-theme` skill.
- "Run my script when the theme changes" → §7 hooks.
- "Is it safe to update?" → `omarchy update available`, then explain §10.
- "Why does my terminal not match my theme?" → §5 templates, `omarchy theme refresh`.