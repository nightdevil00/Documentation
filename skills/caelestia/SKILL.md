---
name: caelestia
description: >
  Expert knowledge for configuring and troubleshooting the Caelestia shell
  (Quickshell-based desktop shell). Portable reference — Caelestia is NOT installed
  on this machine (it runs Hyprland with the stock Omarchy Quickshell shell), so
  REQUIRED when working on a machine that actually runs the Caelestia shell
  (including Caelestia-based Omarchy variants, sometimes called an "omartia" remux):
  editing ~/.config/caelestia/ or ~/.config/quickshell/caelestia/ there, or
  diagnosing bar, lock screen, launcher, dashboard, notifications, OSD,
  wallpaper/theming, or per-monitor behavior of the Caelestia shell. Covers the
  shell.json config schema (global + per-monitor overlays), the C++ Caelestia.Config
  plugin, lock/PAM internals, IPC handlers, Hyprland global shortcuts, the caelestia
  CLI, state files, theming/scheme sync, and rebuild/restart workflows. Triggers:
  caelestia, caelestia shell, shell.json, monitors config, lockscreen, hyprlock
  replacement, PAM fingerprint howdy, bar, dashboard, nexus, launcher, OSD, notifs,
  sidebar, utilities, wallpaper, scheme.json, matugen colors, qs -c caelestia,
  caelestia-shell.service.
---

## 0. Applicability on this machine

**Caelestia is NOT installed here.** No `~/.config/quickshell/caelestia/`, no `~/.config/caelestia/`, no `caelestia` CLI, no `caelestia-shell.service`.

| Topic | This machine | This skill |
|---|---|---|
| Shell | stock Omarchy shell (Quickshell 0.3.1) | `qs -c caelestia` (Caelestia v2.4.0+) |
| Config | `~/.config/omarchy/`, `~/.config/hypr/` | `~/.config/caelestia/shell.json` + `monitors/<SCREEN>/shell.json` |
| Lock/theming | Omarchy's own (`omarchy-system-lock`, `~/.config/omarchy/themes/`) | Caelestia `Lock`/`scheme.json`, optionally bridged to Omarchy (§7, §8) |

Treat §§1, 3 and 8 as *conditional*: they describe a Caelestia install, or a Caelestia-based Omarchy variant. Check each path exists before acting on it.

# Caelestia Shell Skill

Expert agent for the **Caelestia shell**. Grounded in upstream **Caelestia shell
v2.4.0+** (current as of 2026-09; v2.4.0 released early Sept 2026), which runs under
**Quickshell 0.3.1** on **Hyprland 0.56.2** and is often paired with **Omarchy** as
its base (a "remux" where Caelestia replaces omarchy-shell). Those host details —
checkout path, per-monitor overlays, systemd unit name, theme hook — are
install-specific: verify them on the machine in front of you instead of assuming them.

## 0. Primary references

- Upstream repo: <https://github.com/caelestia-dots/shell> (some hosts track it as a git checkout; the Caelestia skill assumes that layout)
- Config schema source of truth: in the shell checkout, `plugin/src/Caelestia/Config/*.hpp` — every option is a `CONFIG_PROPERTY` / `CONFIG_GLOBAL_PROPERTY` macro there. When in doubt, read the hpp.
- Full schema dump with defaults: see `config-schema.md` next to this file.
- Quickshell-level questions: use the `quickshell` skill.

## 1. File map (on a Caelestia install)

Verify each path before relying on it; the dotfiles mirror row is optional and
host-specific.

| Path | What it is |
|---|---|
| `~/.config/quickshell/caelestia/` | The shell itself (often a git repo). `shell.qml` entry, `modules/`, `services/`, `components/`, `plugin/` (C++), `build/` (cmake output incl. QML modules `Caelestia.Config`, `M3Shapes`) |
| `~/.config/caelestia/shell.json` | Global user config (schema in §3) |
| `~/.config/caelestia/monitors/<SCREEN>/shell.json` | Per-monitor config overlay (e.g. `monitors/HDMI-A-1/shell.json`). Same schema; only set keys you want to override |
| `~/.config/caelestia/monitors/<SCREEN>/shell-tokens.json` | Per-monitor token overrides (sizes/fonts/anim tokens) |
| `~/.local/state/caelestia/` | Runtime state: `apps.sqlite` (launcher usage), `notifs.json`, `scheme.json` (current colour scheme), `wallpaper/{current,path.txt,thumbnail.jpg}`, `lyrics/` |
| `~/.config/systemd/user/caelestia-shell.service` | Unit that runs `qs -c caelestia` (PartOf graphical-session.target); some hosts name it differently |
| (optional) `~/Work/dotfiles/caelestia/` | Dotfiles mirror of `~/.config/caelestia/` — if your host keeps one, keep it in sync after edits |

## 2. Architecture essentials

- **One process, many screens**: `qs -c caelestia` loads `shell.qml`, which instantiates `Background`, `Drawers` (bar/dashboard/etc.), `AreaPicker`, `Lock`, `ConfigToasts`, `Shortcuts`, `IdleMonitors`.
- **Screen filtering**: `services/Screens.qml` defines `Screens.screens = Quickshell.screens.filter(s => GlobalConfig.forScreen(s.name).enabled)`. Setting top-level `"enabled": false` in a monitor's overlay removes that screen from ALL shell surfaces (bar, background, drawers).
- **Per-monitor config resolution**: `plugin/src/Caelestia/Config/monitorconfigmanager.cpp` creates a `GlobalConfig` overlay per screen from `~/.config/caelestia/monitors/<SCREEN>/shell.json`. QML code opts in via attached property propagation: e.g. `LockSurface.qml` sets `contentItem.Config.screen: screen.name`, so every `Config.*` lookup beneath that item resolves against that screen's overlay. `Config` is a `QQuickAttachedPropertyPropagator` — attached children inherit the screen automatically.
- **GLOBAL vs per-screen options**: options declared `CONFIG_GLOBAL_PROPERTY` deliberately ignore per-monitor overlays (shared across screens: fprint/howdy settings, transparency, anim duration scale, tray hiddenIcons, workspaces perMonitorWorkspaces, most of `services`). Everything else (`CONFIG_PROPERTY`) can be overridden per monitor.
- **Hot reload**: both global and monitor configs are watched (`QFileSystemWatcher`) and reload live on save. Unknown keys log warnings ("unknownOption") — check logs after adding new keys.

## 3. Config quick reference

Top-level sections of `shell.json` (full details + defaults in `config-schema.md`):

```
enabled            bool   – master switch for THIS screen (monitor overlays only)
appearance         – deformScale, rounding/spacing/padding scale, font {scale, mono}, anim.durations.scale, transparency {enabled,base,layers}
general            – apps {terminal,audio,playback,explorer}, idle {lockBeforeSleep,timeouts[]}, battery {warnLevels,criticalLevel}
background         – enabled, wallpaperEnabled, desktopClock {…}, visualiser {…}
bar                – persistent, showOnHover, dragThreshold, scrollActions, popouts, workspaces {shown,…},
                     activeWindow, tray {hiddenIcons,…}, clock, excludedScreens [regex list]
border             – thickness, rounding, smoothing
dashboard          – enabled, showOnHover, showDashboard/showMedia/showPerformance/showWeather, performance {…}
launcher           – enabled, showOnHover, maxShown, maxWallpapers, specialPrefix "@", actionPrefix ">",
                     enableDangerousActions, vimKeybinds, favouriteApps[], hiddenApps[], useFuzzy {apps,actions,schemes,variants,wallpapers}
lock               – enabled, useWallpaper, recolourLogo, hideNotifs, enableFprint/maxFprintTries,
                     enableHowdy/maxHowdyTries/triggerHowdyOnWake (GLOBAL)
nexus              – wallpapersPerRow, maxNetworksShown, networkRescanInterval
notifs             – expire, fullscreen, defaultExpireTimeout, clearThreshold, expandThreshold, actionOnClick, groupPreviewNum, openExpanded
osd                – enabled, hideDelay, enableBrightness, enableMicrophone
services           – weatherLocation, gpuType, visualiserBars, audioIncrement, brightnessIncrement, maxVolume,
                     smartScheme, defaultPlayer, playerAliases, lyricsBackend (all GLOBAL)
session            – enabled, dragThreshold, vimKeybinds, icons {logout,shutdown,hibernate,reboot},
                     commands {logout[],shutdown[],hibernate[],reboot[]}
sidebar            – enabled, showOnHover, minHoverThreshold, dragThreshold
utilities          – cards {recorder,quickToggles,vpn{provider},keepAwake}, toasts {…per-toast toggles…}
paths              – lyricsDir, sessionGif, mediaGif, noNotifsPic, lockNoNotifsPic ("root:/..." = shell assets)
```

### Worked example — hiding lock UI on one monitor (pattern)

Goal: lock UI (clock/password card) hidden on one output, blurred background kept,
other outputs unaffected. Replace the screen name with your own
(`hyprctl monitors`).

```jsonc
// ~/.config/caelestia/monitors/HDMI-A-1/shell.json
{
    "enabled": false,          // screen already excluded from bar/background/etc.
    "lock": { "enabled": false }  // hides only lockContent (LockSurface.qml: visible: Config.lock.enabled)
}
```

Why it works: `WlSessionLock` still covers every output (a session lock must), but each `WlSessionLockSurface` inherits its screen's config overlay, and only the `lockContent` item is gated by `lock.enabled`. Background stays (screencopy of the screen, or wallpaper if `"useWallpaper": true`). Unlocking works from any screen (PAM is global).

## 4. Lock screen internals

- `modules/lock/Lock.qml`: `WlSessionLock` + one `LockSurface` (auto-created per screen) + `Pam`. Also a screencopy warm-up Loader (first capture fails if the lock is the first ICC request).
- Triggers: CustomShortcuts `lock`/`unlock` (→ Hyprland global shortcuts `caelestia:lock`/`caelestia:unlock`), plus IpcHandler target `lock` (`lock()`, `unlock()`, `isLocked()`).
- Auth: `Quickshell.Services.Pam` PamContext with `configDirectory: Quickshell.shellPath("assets/pam.d")` — custom PAM service files for `passwd`, `fprint`, `howdy` live in the shell's assets. Password card content in `modules/lock/Content.qml` (+ `center/`, `Media.qml`, `NotifDock.qml`, `Resources.qml`, `weather/`, `Fetch.qml`).
- Idle integration: `IdleMonitors.qml` plus `general.idle.timeouts` ship with the shell, but how (or whether) they are wired to the host compositor's idle daemon is host-specific — see §8 for the common patterns.

## 5. IPC & shortcuts

List live commands with `caelestia shell -s` (while running). Call with:
`qs -c caelestia ipc call <target> <function> [args…]`.

| Target | Functions |
|---|---|
| `lock` | `lock()`, `unlock()`, `isLocked()` |
| `nexus` | `toggle(drawer)`, `open()` |
| `toast` | `info(title,message,icon)`, `success(...)` |
| `areaPicker` | `open()`, `openFreeze()` |
| `audio` | `cycleOutput()` |
| `brightness` | `get()`, `getFor(query)` |
| `gameMode` | `isEnabled()`, `toggle()` |
| `hypr` | `refreshDevices()`, `cycleSpecialWorkspace(direction)` |
| `idleInhibitor` | `isEnabled()`, `toggle()` |
| `notifs` | `clear()`, `isDndEnabled()` |
| `players` | `getActive(prop)`, `list()` |
| `wallpapers` | `get()`, `set(path)` |

CustomShortcuts (Hyprland global shortcuts, bindable as `hl.dsp.global("caelestia:<name>")`):
`nexus`, `showall`, `dashboard`, `session`, `launcher`, `launcherInterrupt`, `sidebar`,
`utilities`, `lock`, `unlock`. A Hyprland host binds them in its own Hyprland config
(e.g. `~/.config/hypr/bindings.lua`) — a common set is SUPER+SPACE launcher,
SUPER+ALT+SPACE session, SUPER+N sidebar, SUPER+ALT+D dashboard, SUPER+CTRL+L lock.
Check the host's real bindings rather than assuming these.

## 6. CLI (`caelestia` python script; upstream installs it to `/usr/bin/caelestia`)

Confirm the path on your host with `command -v caelestia` first.

```
caelestia shell [-d|-s|-l|-k] [message…]   # start daemon / print IPC cmds / print log / kill
caelestia toggle <ws>                      # toggle special workspace
caelestia scheme list|get|set              # colour scheme management
caelestia screenshot [mode]                # screenshot (uses areaPicker IPC)
caelestia record                           # screen recording
caelestia clipboard                        # clipboard history
caelestia emoji                            # emoji/glyph picker
caelestia wallpaper -f FILE | -r [DIR] | -p | -N   # switch/random/print; -N disables smart mode switching
caelestia resizer                          # window resizer daemon
caelestia install | update                 # dotfiles installer/updater
```

## 7. Theming pipeline

- Current scheme lives in `~/.local/state/caelestia/scheme.json`: `{name, mode, variant, colours:{m3 roles}}`. Generated from the wallpaper via material-you colour extraction (`caelestia wallpaper` triggers it; `services.smartScheme` auto-picks dark/light by wallpaper luminance).
- `services/Colours.qml` reads scheme.json (FileView watch) → exposes `Colours.palette.m3*` + transparency used by all modules.
- **Optional Omarchy bridge**: on Caelestia-based Omarchy variants, a `theme-set.d` hook (typically `~/.config/omarchy/hooks/theme-set.d/caelestia-sync.sh`) converts the active Omarchy theme's `colors.toml` into `scheme.json` whenever the host's theme is switched. Such a hook is host-local — check that it exists before relying on it, and if colours look stale after a theme change, run the hook manually and read its stderr.
- Wallpaper state: `~/.local/state/caelestia/wallpaper/path.txt` + `current` (symlink) + cached thumbnail.

## 8. Host-specific wiring (only on Caelestia-based Omarchy variants)

Nothing in this section is upstream Caelestia; it describes what a "remux" that swaps
omarchy-shell for Caelestia typically adds. Confirm each piece exists on the host
before debugging lock/idle against it.

- Autostart: `~/.config/hypr/autostart.lua` may import the environment then
  `systemctl --user start caelestia-shell.service`, with Omarchy's own shell autostart
  stubbed out.
- Keybinds call the shell directly via global shortcuts (`hl.dsp.global("caelestia:*")`)
  — these always work while the service runs.
- Idle/lock wiring: some hosts ship `~/.local/bin/caelestia-system-lock` as a
  replacement for `omarchy-system-lock` — it calls `qs -c caelestia ipc call lock lock`,
  then replicates the omarchy extras (kb layout reset, 1password lock, screensaver
  kill). `~/.config/hypr/hypridle.conf` then points `lock_cmd`/`before_sleep_cmd`/
  listener at it. hypridle must be installed (`pacman -S hypridle`) and autostarts via
  `autostart.lua`.
- Caelestia ALSO has built-in idle handling (`IdleMonitors.qml` + `general.idle.timeouts`
  defaults: 180s→lock, 300s→dpms off (+return), 600s→suspendThenHibernate, plus
  `lockBeforeSleep` via logind PrepareForSleep). It runs regardless of hypridle; if both
  are active they coexist (both are idempotent, and whichever fires first wins).
- Per-monitor overlays are per-host: a second output is often set to `"enabled": false`
  with lock UI hidden (see §3). Check `hyprctl monitors` for your own output names.

## 9. Troubleshooting workflow

```bash
systemctl --user status caelestia-shell        # running? since when?
qs list --all                                  # instance + config path + display
caelestia shell -l                             # shell log (or: journalctl --user -u caelestia-shell -e)
qs -c caelestia ipc call lock isLocked         # smoke-test IPC (expect true/false)
python3 -m json.tool ~/.config/caelestia/shell.json   # validate JSON after edits
```

- **Edit didn't apply**: config files hot-reload, but a JSON syntax error blocks load and the shell keeps old values — check the log for parse errors / "unknownOption" warnings.
- **QML error**: module loads partially or dies; log shows the QML stack. `settings.watchFiles: true` means saving any shell .qml file restarts the affected components live.
- **Changed C++ plugin code** (`plugin/src/...`): rebuild required:
  ```bash
  cd ~/.config/quickshell/caelestia && cmake --build build   # outputs to build/qml + build/lib
  systemctl --user restart caelestia-shell
  ```
  The running instance imports `Caelestia.Config`/`M3Shapes` from the config-local `build/qml` dir.
- **Bar missing on a screen**: check `Screens.screens` filter (root `enabled`), then `bar.excludedScreens` regexes, then `hyprctl monitors` name spelling (overlay dir must match `screen.name` exactly, e.g. `HDMI-A-1`).
- **Full reset**: `systemctl --user restart caelestia-shell`; nuclear option `caelestia shell -k` then start again (substitute your host's unit name if it differs).
- If your host keeps a dotfiles mirror of `~/.config/caelestia/`, sync it after accepted changes (the user will usually ask).

## 10. Extending safely

- New config option = add `CONFIG_PROPERTY`/`CONFIG_GLOBAL_PROPERTY` in the right hpp + rebuild plugin; document it in `config-schema.md`.
- Prefer per-monitor overlays over code changes for per-screen behavior; prefer IPC/shortcuts for scripting.
- Never edit the shell repo without checking `git status` first — it's a live git checkout; upstream updates land via `git pull` (dotfiles update flow), so local uncommitted patches can conflict. Commit locally or keep patches minimal.
