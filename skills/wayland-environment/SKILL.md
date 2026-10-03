---
name: wayland-environment
description: >
  Expert knowledge for the Wayland desktop environment layer on Arch Linux —
  XDG Desktop Portals (xdg-desktop-portal + backends), XDG Runtime dir/session
  environment, session management (graphical-session.target, environment.d),
  common Wayland protocols and conventions, and per-app Wayland enablement
  (env vars, socket modules). REQUIRED when diagnosing portal failures
  (screenshare, file pickers, global shortcuts), Wayland clipboard/DRAG&drop
  issues, Gtk/Electron/Qt Wayland quirks, XDG autostart, or environment
  variables for Wayland apps, complementary to the hyprland and systemd skills.
  Triggers: xdg-desktop-portal, xdg-desktop-portal-wlr/hyprland/gnome, portals,
  XDG_RUNTIME_DIR, WAYLAND_DISPLAY, XDG_SESSION_TYPE, environment.d,
  graphical-session, screenshare, pipewire portal, global shortcut portal,
  file picker portal, GTK Wayland, Electron Wayland, Qt Wayland, ozone,
  QT_QPA_PLATFORM, GDK_BACKEND, XDG_CURRENT_DESKTOP, XDG_SESSION_DESKTOP,
  xdg-desktop-portal-gtk, screenshot portal, remote desktop portal.
---

# Wayland Environment Skill

Expert agent for the **Wayland desktop environment layer** on this machine.
**Hyprland** is the compositor and the **Omarchy Quickshell** the shell; the
"desktop environment plumbing" between user apps and compositor is handled by
the XDG runtime, the session environment, and **XDG Desktop Portals**. This
skill is the companion to the `hyprland`, `omarchy`, `quickshell`, `sddm`,
`systemd`, and `arch` skills.

## 0. Primary references

- **Arch Wiki — Wayland**: <https://wiki.archlinux.org/title/Wayland>
- **Arch Wiki — XDG Desktop Portal**: <https://wiki.archlinux.org/title/XDG_Desktop_Portal>
- **Arch Wiki — Environment variables**: <https://wiki.archlinux.org/title/Environment_variables>
- **Arch Wiki — Xwayland**: <https://wiki.archlinux.org/title/Xwayland>
- **wayland-protocols (green Steele)**: <https://gitlab.freedesktop.org/wayland/wayland-protocols>
- **XDG Base Directory spec**: <https://specifications.freedesktop.org/basedir-spec/latest/>
- **xdg-desktop-portal docs**: <https://flatpak.github.io/xdg-desktop-portal/>
- **freedesktop portals protocol (D-Bus)**: <https://flatpak.github.io/xdg-desktop-portal/portal-docs.html>
- See also the **hyprland** skill for compositor specifics and the **systemd**
  skill for user-session wiring.

### Verified session values on this machine
```text
XDG_CURRENT_DESKTOP=Hyprland     XDG_SESSION_DESKTOP=Hyprland
XDG_SESSION_TYPE=wayland          XDG_SESSION_CLASS=user
WAYLAND_DISPLAY=wayland-1         XDG_RUNTIME_DIR=/run/user/1000
DISPLAY=:0                        # Xwayland IS running
```
Portals installed: `xdg-desktop-portal 1.22.1`, `xdg-desktop-portal-gtk
1.15.3`, `xdg-desktop-portal-hyprland 1.4.1`, `libportal 0.11.0`. All four
services are active. Confirm before citing:
`pacman -Q | grep portal`.

## 1. Core Wayland environment concepts

### Session variables
Set by the login/session manager (here SDDM → uwsm → Hyprland):
- `WAYLAND_DISPLAY=wayland-1` — the Wayland socket in `$XDG_RUNTIME_DIR`.
- `XDG_RUNTIME_DIR=/run/user/<uid>` — the per-user runtime dir (must be
  owned by the user, mode 0700; systemd creates/sets it). Many Wayland apps
  hard-fail without it.
- `XDG_SESSION_TYPE=wayland`, `XDG_SESSION_DESKTOP=Hyprland`,
  `XDG_CURRENT_DESKTOP=Hyprland` — desktop hints for portal selection & app
  behavior. The value is capitalised here; `Hyprland` is what the portal
  backends match against.
- `DISPLAY` — absent on a pure Wayland session. **Here it is set to `:0`**, so
  Xwayland is running; do not assume an app is Wayland-native just because the
  session is.

### XDG Base Directory spec
- `XDG_CONFIG_HOME` (`~/.config`), `XDG_DATA_HOME` (`~/.local/share`),
  `XDG_STATE_HOME` (`~/.local/state`),
  `XDG_CACHE_HOME` (`~/.cache`), `XDG_DESKTOP_DIR`, `XDG_DOCUMENTS_DIR`, etc.
- These matter for where the shell stores things (Omarchy config in
  `~/.config/omarchy/`, live state in `~/.local/state/omarchy/`) and for
  `~/.config/hypr/`. The `omarchy` and `hyprland` skills reference them.

## 2. XDG Desktop Portals (the modern API)

### What portals are
Portals let sandboxed or Wayland apps request privileged/desktop-wide services
over D-Bus: file open/save dialogs, screensharing, global shortcuts, screenshot
capture, color picker, wallpaper setting, printing, network location, power
profile, etc. The **portal service** (`xdg-desktop-portal`) dispatches to a
**backend** for the specific desktop environment:

| Portal backend | Used by |
|---|---|
| `xdg-desktop-portal-gtk` | GTK apps / minimal DEs |
| `xdg-desktop-portal-hyprland` | Hyprland |
| `xdg-desktop-portal-wlr` | wlroots compositors (sway, Hyprland pre-2024) |
| `xdg-desktop-portal-gnome` | GNOME |
| `xdg-desktop-portal-kde` | KDE (incl. org.kde.Kglobalaccel for global shortcuts) |
| `xdg-desktop-portal-lxqt`, etc. | |

**On Hyprland** run `xdg-desktop-portal-hyprland` for compositor-specific
interfaces and `xdg-desktop-portal-gtk` for the rest (FileChooser and friends).
Both are active here. Some DE backends must be pinned as default via an env var.

### Installation & service (Arch)
```bash
sudo pacman -S xdg-desktop-portal xdg-desktop-portal-gtk
# user service (run as your user session service):
systemctl --user enable --now xdg-desktop-portal xdg-desktop-portal-gtk
# or just let the session start it (graphical-session.target Wants)
```
Current as of 2026-09: upstream **xdg-desktop-portal 1.22.x** (1.22.1, June 2026);
backend packages (`-gtk`, `-hyprland`, `-gnome`, `-kde`) track their own versions —
confirm with `pacman -Q xdg-desktop-portal*` before citing.

### Key backends on Hyprland
- **File dialogs**: the Gtk backend provides `org.freedesktop.portal.FileChooser`.
- **Screen capture / screenshare**: apps request a PipeWire `ScreenCast` via
  `org.freedesktop.portal.ScreenCast`; the portal grants the stream. On Hyprland,
  the compositor exposes capture to e.g. `grim`/`wf-recorder` (native pipewire,
  often no portal needed for simple CLI), but **browser screenshare** (Meet,
  Discord, etc.) uses the portal + PipeWire. If screenshare fails, the portal
  backend or pipewire node is the usual culprit. Omarchy's own capture path is
  `omarchy capture-screenrecording` / `omarchy capture-screenshot`.
- **Global shortcuts**: `org.freedesktop.portal.GlobalShortcuts` lets apps bind
  global keys (this is also what Quickshell's `GlobalShortcut` uses). The
  `kde` backend implements it most fully. On Hyprland, `XDG_CURRENT_DESKTOP`
  is already `Hyprland` so the correct backend is selected automatically;
  otherwise the fallback is a Hyprland `bind` using Quickshell's
  `CustomShortcut` (see `quickshell` and `hyprland` skills).

### Troubleshooting portals
```bash
# is the portal service running?
systemctl --user status xdg-desktop-portal xdg-desktop-portal-gtk
# logs
journalctl --user -u xdg-desktop-portal -e --no-pager
journalctl --user -u xdg-desktop-portal-gtk -e --no-pager
# which backend is being selected? check `dbus-monitor` on the D-Bus session,
# or run the portal daemons with verbose logging.

# environment hint: only needed if XDG_CURRENT_DESKTOP is wrong or unset
# printf 'XDG_CURRENT_DESKTOP=Hyprland\n' > ~/.config/environment.d/10-desktop.conf
```
- **Portal started at wrong time**: the portal must start after the session
  bus is up. Ensure it's WantedBy=`graphical-session.target` (user unit) and
  that `XDG_SESSION_TYPE=wayland` is set — a common cause of no-screenshare is
  the portal thinking it's an X11 session.
- **Backend choice matters.** On Hyprland, `-hyprland` should be active and
  `-gtk` supplies the rest (FileChooser etc.) — both running is correct here,
  not a conflict. Only mask one when it genuinely duplicates another
  (e.g. `-gnome` alongside `-gtk`):
  `systemctl --user mask xdg-desktop-portal-gnome`.

## 3. Per-app Wayland enablement (env vars)

Arch Wiki table: <https://wiki.archlinux.org/title/Wayland#GUI_libraries>.
Common env for Wayland sessions (put in `~/.config/environment.d/*.conf`):

```ini
# GTK
# (default; GDK_BACKEND=wayland only forces it)
# GDK_BACKEND=wayland,x11

# Qt
QT_QPA_PLATFORM=wayland;xcb
QT_WAYLAND_DISABLE_WINDOWDECORATION=1

# Electron / Chromium
ELECTRON_OZONE_PLATFORM_HINT=auto
# CHROME_OZONE_PLATFORM_HINT=auto  (older name)

# Java/AWT (Xwayland needs non-reparenting)
_JAVA_AWT_WM_NONREPARENTING=1

# nvidia/libva
LIBVA_DRIVER_NAME=nvidia
__GLX_VENDOR_LIBRARY_NAME=nvidia
WLR_NO_HARDWARE_CURSORS=1          # only if cursors glitch on wlroots

# misc
MOZ_ENABLE_WAYLAND=1               # Firefox
OBS_USE_EGL=1
```

- Environment set via `environment.d` applies to the user systemd manager →
  inherited by graphical session and user services. It does NOT apply to apps
  you launch from SSH or a bare TTY (use the session-level approach for those).
- Omarchy sets `ELECTRON_OZONE_PLATFORM_HINT=auto` in the session environment;
  verify with `systemctl --user show-environment | grep -i ozone`.

## 4. Screenshot / screen capture (Wayland)

- **Shortcuts** here: `omarchy screenshot` (or `omarchy capture-screenshot`).
  Hyprland's own binder is `hyprctl dispatch exec 'grim -g "$(slurp)"'`.
  See the `hyprland` skill §8 and `omarchy` skill §11.
- **Portal-based capture**: `grim -g "$(slurp)"` works directly; recording via
  `wf-recorder` also direct. Browsers use the portal (`ScreenCast`); that path
  fails when the portal backend isn't configured — see §2.

## 5. Clipboard (Wayland)

- `wl-clipboard` (`wl-copy`, `wl-paste`) is the standard clip util.
- Noctalia provides a clipboard manager section in its config if enabled.
- **Clipboard across apps/sessions**: wl-clipboard on Wayland uses the
  `wlr-data-control` protocol (or the compositor's implementation). If pasting
  between a Qt app and browser fails, the compositor or a `wl-paste -w`/`wl-paste
  --watch` daemon may be the issue. Hyprland's `misc:disable_primary_selection`
  controls primary-selection behaviour — see the `hyprland` skill.

## 6. Wayland protocols quick map

| Protocol | Meaning | Typical need |
|---|---|---|
| `wl_surface`/`wl_shell` (legacy) | base window | all apps |
| `xdg-shell` | modern toplevels (titles, rules) | most GUIs |
| `wlr-layer-shell` | bars/overlays/launchers | the Omarchy shell (Quickshell) |
| `wlr-foreign-toplevel` | window management clients | taskbars, scripting |
| `ext-workspace-v1` | workspace info | the bar's workspaces widget |
| `zwlr_screencopy_v1` | screenshots/recording | grim, wf-recorder |
| `zwp_pointer_constraints` | pointer lock | games, remote desktop |
| `wp_presentation` | vsync timing | compositors |
| `zt_global_shortcuts` / InterpolatedShortcuts | global keys | shell shortcuts |
| `ghost_XDragon` (not standard) | drag&drop | unusual case |
| `wayland-drm` | buffers for NVIDIA | older wlroots |

Hyprland implements `ext-workspace-v1`, which the bar's workspaces widget uses.
Check with `hyprctl descriptors` if workspace behaviour looks wrong.

## 7. Xwayland on Hyprland

- Hyprland starts **Xwayland** as part of the session; `DISPLAY` is set to `:0`
  here. X11 apps appear as regular windows.
- An X11 app getting KMS screen capture may need to run native Wayland instead;
  otherwise captures fall back to the Xwayland path.
- See the `hyprland` skill.
- Portal `ScreenCast` on X11 windows: some apps must run native Wayland to
  benefit from KMS screen capture; otherwise captures go through the Xwayland
  path only if the tool supports it.

## 8. Session autostart (XDG autostart / graphical-session)

Ways apps start with the desktop:
- **`~/.config/systemd/user/*.service`** — `WantedBy=graphical-session.target`,
  `PartOf=graphical-session.target` (see the `systemd` skill).
- **`~/.config/autostart/*.desktop`** (XDG autostart) — started by uwsm's
  `wayland-session-xdg-autostart@hyprland.desktop.target`. This is what
  `/usr/share/omarchy/config/autostart/*.desktop` entries rely on.
- **Hyprland `exec-once` / `exec`** — for compositor-level startup, in
  `~/.config/hypr/autostart.lua` (see the `hyprland` skill).
- **The Omarchy shell** is started by uwsm/`omarchy launch shell`, not by
  either of the above — do not hand-write a unit for it.
- Service ordering: put session-critical user services (wireplumber, portal)
  WantedBy/After `graphical-session.target`.

## 9. Troubleshooting workflow

```bash
# 1. Session env sanity (does the desktop know it's Wayland?)
echo $XDG_SESSION_TYPE $XDG_SESSION_DESKTOP $XDG_CURRENT_DESKTOP $WAYLAND_DISPLAY
# 2. Runtime dir
ls -ld "$XDG_RUNTIME_DIR"; ls "$XDG_RUNTIME_DIR" | grep wayland
# 3. Portal running?
systemctl --user status xdg-desktop-portal xdg-desktop-portal-gtk
# 4. Portals seen by an app?
dbus-send --session --dest=org.freedesktop.DBus \
  --print-reply /org/freedesktop/DBus \
  org.freedesktop.DBus.ListNames | grep -i portal
# 5. Wayland socket/protocol issue in an app?
wayland-info            # protocol list + globals
# 6. XDG autostart/services not starting at login?
journalctl --user -b | grep -i portal
```

### Common failure classes
- **No file picker / app "can't open files"** → portal backend missing or
  wrong; ensure `xdg-desktop-portal-gtk` enabled.
- **Browser screenshare black / no share** → portal ScreenCast backend;
  check `journalctl --user -u xdg-desktop-portal*`; check pipewire running
  (`systemctl --user status pipewire wireplumber`).
- **Global shortcuts don't fire in apps (Discord PTT, etc.)** → portal
  GlobalShortcuts backend; otherwise bind via Quickshell `CustomShortcut`.
- **App launches but is not Wayland** → it fell back to Xwayland; set its env
  var (`ELECTRON_OZONE_PLATFORM_HINT=auto`, `MOZ_ENABLE_WAYLAND=1`, ...) and
  restart the app.
- **Screenshot gives black/empty on NVIDIA** → use portal/`grim` KMS path;
  check `nvidia-drm.modeset=1` and `GAMING`.
- **Portal service race**: make sure `graphical-session.target` ordering is
  sane (portal After=session), else the first app requesting a portal may hang.

## 10. Safety rules

- **Never start the portal as root.** User services under `--user` only.
- Don't install two conflicting backends (hyprland + gtk) without masking one.
- Prefer user-scoped `environment.d` for env vars; avoid polluting `/etc/environment`.
- Test env-var changes by relaunching the app, not by assuming reload.
- Read <https://wiki.archlinux.org/title/XDG_Desktop_Portal> before reconfiguring.

## Example requests

- "Screenshare in browser shows nothing" → portal ScreenCast backend + pipewire checks above.
- "No file-picker when app opens a file" → ensure `xdg-desktop-portal-gtk` user service.
- "Discord PTT doesn't work globally" → GlobalShortcuts portal; else a Quickshell `CustomShortcut`.
- "Why is Firefox running X11?" → `MOZ_ENABLE_WAYLAND=1` via environment.d.
- "App can't write config anywhere" → XDG dirs misconfigured; verify `echo $XDG_CONFIG_HOME`.
- "Portal service fails to start" → check ordering + session env; logs in `journalctl --user`.