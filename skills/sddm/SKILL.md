---
name: sddm
description: >
  Expert knowledge for configuring and troubleshooting the SDDM display/login
  manager, which provides this machine's graphical login (greeter) screen.
  REQUIRED when diagnosing login issues, missing sessions, login-loop,
  black/no screen at boot into greeter, theme problems, or per-user session
  behavior, or when editing anything under /etc/sddm.conf.d/ or
  /usr/share/sddm/themes/ or ~/.local/share/sddm/themes/. Covers the SDDM
  config format, QML themes, Wayland greeter (sddm-greeter-qt6), session
  selection and startup, PAM integration, autologin, environment files,
  Wayland/Compton compositor backend, user sessions (.desktop session files),
  and troubleshooting. Triggers: sddm, login screen, greeter, can't log in,
  login loop, black screen sddm, sddm.conf, sddm theme, sddm wayland greeter,
  sddm autologin, sddm PAM, session not showing, sddm won't start, sddm fails,
  login manager.
---

# SDDM Skill

Expert agent for **SDDM (Simple Desktop Display Manager)** — the graphical
login (greeter) manager used by many Arch Linux desktops, including this
machine. Current as of 2026-09: latest upstream release is still **0.21.0**
(2024-02-26); distros ship it plus git snapshots (Qt6 greeter standard,
no 0.22/1.0 yet). SDDM is built on Qt; it displays a greeter, authenticates the user
(via PAM), and starts the selected desktop/Wayland/X11 session.

## 0. Primary references

- **Arch Wiki (SDDM)**: <https://wiki.archlinux.org/title/SDDM>
- **Display manager (general)**: <https://wiki.archlinux.org/title/Display_manager>
- **SDDM GitHub**: <https://github.com/sddm/sddm>
- **SDDM manual/config**: <https://github.com/sddm/sddm/wiki>
- **SDDM themes (AUR et al.)**: e.g. <https://github.com/Kangie/sddm-astronaut-theme> (or your installed theme)
- **Wayland greeter info**: <https://wiki.archlinux.org/title/SDDM#Wayland>
- **Session files**: `/usr/share/wayland-sessions/*.desktop` and `/usr/share/xsessions/*.desktop`
- **Loginctl / session control**: <https://wiki.archlinux.org/title/General_troubleshooting#Session_reset>

## 1. What SDDM is / how it fits

- SDDM is the thing that shows the **login (greeter) screen** and hands off to
  your desktop session. On this machine the session is **Hyprland** (Wayland)
  with the **Omarchy** Quickshell, launched through **uwsm** — so the session
  SDDM starts is `hyprland-uwsm`, and the greeter runs Hyprland itself as a
  nested compositor. See §1.1.
- Process layout: a systemd **`sddm.service`** (Display Manager) runs the **SDDM**
  daemon; it spawns the **greeter** (either X11 `sddm-greeter` or Wayland
  `sddm-greeter-qt6`) which shows the UI and authenticates. On success it starts
  the user's **session** in a new loginctl session and runs the session command.
- **Why DE login works but TTY-form login doesn't** or vice-versa is usually
  PAM, session-file, or environment related — the sections below cover each.

### Package layout
```text
sddm                          # sddm binary, config, X11 greeter (sddm-greeter)
sddm-kcm                     # system-settings KCM module (Qt6 Settings app)
qt6-qtdeclarative             # runtime for the QML greeter
sddm-theme-*                  # themes (via PKGBUILD or AUR)
```

### 1.1 How this machine actually wires it

Verified here — use this as the reference topology when reasoning about login
failures.

Available Wayland sessions in `/usr/share/wayland-sessions/`: `hyprland.desktop`
and `hyprland-uwsm.desktop`. The latter is what SDDM autoloads:

```ini
[Desktop Entry]
Name=Hyprland (uwsm-managed)
Exec=uwsm start -e -D Hyprland hyprland.desktop
TryExec=uwsm
DesktopNames=Hyprland
```

So the chain is:

```
sddm.service  →  sddm-greeter (Wayland)  →  nested Hyprland  →  auth via sddm-helper
   →  uwsm start -e -D Hyprland hyprland.desktop
        →  wayland-wm@hyprland.desktop.service        (main service, running)
        →  wayland-wm-env@hyprland.desktop.service    (environment preloader, exited)
        →  wayland-session@hyprland.desktop.target    (the session)
             ├ wayland-session-pre@…target             (preparation)
             ├ wayland-session-envelope@…target        (envelope)
             └ wayland-session-xdg-autostart@…target   (XDG autostart)
        →  app-<WM>-<name>-<hash>.scope                (per-app launcher scopes)
```

The greeter's nested compositor comes from `/etc/sddm.conf.d/10-wayland.conf`:

```ini
[General]
DisplayServer=wayland

[Wayland]
CompositorCommand=start-hyprland -- --config /usr/share/sddm/hyprland.lua
```

Two consequences worth internalising:

- **SDDM does not launch the compositor directly.** It launches `uwsm`, which
  owns the systemd user units. That is why `systemctl --user` units exist for
  the session but there is no `uwsm.service` — uwsm is a client of systemd,
  not a service.
- **`omarchy restart app <name>` goes through uwsm** and therefore creates an
  `app-Hyprland-<name>-<hash>.scope`. A "ghost" process you cannot kill is
  usually one of those scopes; stop it with `systemctl --user stop <scope>`.

Also present: `/etc/sddm.conf.d/autologin.conf` (`User=mihai`,
`Session=hyprland-uwsm`) and `99-omarchy-login.conf`
(`RememberLastUser=true`, `RememberLastSession=true`). Autologin means a broken
greeter theme can still produce a working-looking desktop — and, conversely, a
"login problem" may never reach SDDM at all. Check whether autologin is
enabled before blaming the greeter.

## 2. Config format

- **Primary config file**: `/etc/sddm.conf` (often generated by `sddm --example-config`).
- **Drop-in overrides**: `/etc/sddm.conf.d/<name>.conf` — these OVERRIDE
  `/etc/sddm.conf` and are merged (later/`*.conf` sorted). This is the
  recommended way to customize without fighting package updates. Arch Wiki
  recommends using drop-ins.
- The theme's per-theme config lives inside the theme directory (e.g.
  `theme.conf` in the theme dir) or via `[Theme]` `Current=` + theme files.

### Minimal example drop-in
```ini
# /etc/sddm.conf.d/10-session.conf
[Autologin]
Session=hyprland-uwsm      # exact filename in /usr/share/wayland-sessions/
User=<username>

# /etc/sddm.conf.d/20-theme.conf
[Theme]
Current=astronaut
```

### Key config sections

```ini
[General]
# HaltCommand=/usr/bin/systemctl poweroff
# RebootCommand=/usr/bin/systemctl reboot
Numlock=none            # on|off|none  (default none)
EnvironPath=/usr/bin:/usr/local/bin
DaemonPath=/usr/bin

[Theme]
Current=breeze          # theme dir name under /usr/share/sddm/themes/
CursorTheme=breeze_cursors
# Font=...

[Users]
DefaultPath=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin
# MaximumUid=  HideShells=  HideUsers=  RememberLastUser=true

[Wayland]
# Compositor=weston
# EnableHiDPI=true

[X11]
# ServerPath=/usr/bin/X
# EnableHiDPI=true

[Autologin]
# Session=   User=    Relogin=false

[Display]
# ServerArguments=-nolisten tcp
# MinimumVT=1
# GreeterEnvironment=QT_SCREEN_SCALE_FACTORS=...
```

## 3. Starting / enabling SDDM

- **Enable on boot**: `systemctl enable sddm`
  (that symlinks `display-manager.service` → `sddm.service`).
- **Only one display manager should be enabled.** If you previously enabled
  `gdm`/`lightdm`/`lxdm`, running `systemctl disable gdm` first avoids conflicts
  (the `display-manager.service` alias can only point at one).
- Check which DM is aliased: `systemctl status display-manager` shows which.
- **Important (Arch quirk)**: On Arch, enabling `sddm` via
  `systemctl enable sddm` is correct; installing via a DE meta or using the
  default should use the `display-manager.service` alias handled by pacman
  hooks only if configured. Prefer explicit `systemctl enable sddm`.

### Start/stop/restart
```bash
systemctl start sddm                     # starts greeter now (from a TTY)
systemctl stop sddm                      # back to TTY
systemctl restart sddm
systemctl status sddm                    # state + recent journal
```

## 4. Wayland greeter (sddm-greeter-qt6)

- Modern SDDM uses a **Qt6 Wayland greeter** by default (package
  `sddm-greeter-qt6` on Arch). It runs as a Wayland client; the compositor it
  uses for the greeter can be `weston` or the built-in one.
- If the Wayland greeter fails (e.g., no GPU/weston), you can fall back to X11
  greeter by setting in drop-in:
  ```ini
  [Wayland]
  Compositor=weston
  EnableHiDPI=true
  ```
  or configure `[General] InputMethod=` etc. Check the Arch Wiki section
  <https://wiki.archlinux.org/title/SDDM#Wayland>.
- The Wayland greeter needs a working wayland compositor at greeter time. If
  your desktop session works but SDDM's greeter is black, the greeter
  compositor (`[Wayland] CompositorCommand=`, `weston` upstream, Hyprland here)
  or its GL/EGL may be the issue — not your desktop config.

## 5. Themes

- Installed theme dirs: `/usr/share/sddm/themes/<name>/` (system) and
  `~/.local/share/sddm/themes/<name>/` (per-user). Per-user themes require the
  theme dir to be readable and the theme to be listed in `[Theme] Current=`.
- List themes: `ls /usr/share/sddm/themes/`.
- Set: `[Theme] Current=<dir-name>` in a drop-in, e.g. `/etc/sddm.conf.d/theme.conf`.
- Common themes (AUR): `sddm-astronaut-theme`, `sddm-sugar-dark`,
  `sddm-almond`, `sddm-nordic`, `archlinux-sddm-theme-*`. Some need a font/nerd
  font and `qt5-svg`/icon themes.
- Test a theme without affecting boot: run the greeter manually is tricky;
  better: temporarily set `[Theme] Current=` and `systemctl restart sddm`.
- Theme config: inside the theme dir, a `theme.conf` holds `[General]` keys the
  QML reads (`Background`, `Loglevel`, etc.). Some themes expose a `theme.conf.d`/
  UI to live-edit.
- **Fixing a broken theme**: if the wrong theme shows a black/error screen, it
  may still be interactive (background image path broken). Set `Current=breeze`
  (the fallback) to rule theme issues out.

## 6. Session selection & session files

- SDDM lists sessions from:
  - Wayland: `/usr/share/wayland-sessions/*.desktop`
  - X11: `/usr/share/xsessions/*.desktop`
  - (User overrides rarely used; most install system-wide.)
- To have **Hyprland** appear as a login option, the packages provide
  `/usr/share/wayland-sessions/hyprland.desktop` and
  `hyprland-uwsm.desktop`. Verify:
  ```bash
  ls /usr/share/wayland-sessions/    # here: hyprland.desktop, hyprland-uwsm.desktop
  ```
  Add your own with an `Exec=` wrapper that starts uwsm; see §1.1.
- If your session is missing from the greeter's session dropdown:
  - The `.desktop` is absent or has a bad `Exec=`/`Comment=`.
  - File must be world-readable (`-rw-r--r--`) and owned by root.
  - For uwsm-managed sessions, `Exec=uwsm start -e -D Hyprland hyprland.desktop`
    with `TryExec=uwsm` and `DesktopNames=Hyprland`.
- `[Autologin] Session=<name>.desktop` must match the filename exactly
  (here `Session=hyprland-uwsm`). `Session=` takes the **basename with
  `.desktop`**, not a path.

## 7. PAM integration (authentication)

- SDDM uses PAM to authenticate. On Arch the relevant config is
  `/etc/pam.d/sddm` (and `sddm-greeter`). Read them before assuming the issue
  is SDDM — PAM rules can fail auth even when the password is correct.
- If fingerprint/Howdy or other auth is desired on the login screen, that must
  be wired into `/etc/pam.d/sddm`. The desktop lock screen is a separate
  component with its own PAM service — on Omarchy that is the shell's lock
  plugin (see the `omarchy-plugin` skill), not SDDM.
- **Test auth independently** of SDDM: `su - <user>` or a TTY login
  (`Ctrl+Alt+F2`) verifies the password/PAM independently of the greeter.

## 8. Environment & cleanup on session start/stop

- On successful login SDDM starts the session command (here, `uwsm start …`)
  in a new session. It sets basic env (`XDG_RUNTIME_DIR`, `XDG_SESSION_*`,
  `WAYLAND_DISPLAY` for Wayland sessions via the `.desktop`/greeter).
- For per-user environment, prefer `~/.config/environment.d/*.conf`
  (loaded by systemd user manager when the session starts) over greeter env.
  See <https://wiki.archlinux.org/title/Environment_variables>.
- **Cleanup**: on session end SDDM returns to the greeter. If your desktop
  shell/service lingers, `systemctl --user` units bound to
  `graphical-session.target` should stop automatically; orphaned processes are
  a separate (possible) cause of "loop back to login".

## 9. Troubleshooting workflow (login issues)

Follow this order. The most common failure modes and their fixes:

### A. SDDM never appears (black screen / TTY at boot)
```bash
systemctl status sddm
journalctl -u sddm -b --no-pager     # full boot log for sddm
```
- **sddm.service not running** → enabled? `systemctl is-enabled sddm`;
  start it: `systemctl start sddm`.
- **Greeter crashes** → check `journalctl -u sddm -e` for `sddm-greeter`
  crash/segfault (see `diagnose-crash` skill for core dumps). Common: missing
  weston/wayland greeter, GPU/EGL failure.
- **NVIDIA + Wayland greeter black** → try fallback to `weston` or X11
  greeter; check `nvidia-drm.modeset=1`; ensure `mesa`/egl working.
- **VT issue**: SDDM runs on VT7 by default. If it appears on wrong VT or a
  commit problem, `loginctl`/`systemctl restart sddm`; check boot with
  `journalctl -b | grep -i vt`.

### B. SDDM shows but login fails / loop back to greeter
```bash
journalctl -u sddm -b | grep -iE 'fail|error|pam|auth'
```
- Verify the password works out-of-band: TTY login or `su -`. If TTY login
  fails too → user/PAM issue, not SDDM.
- Check `/etc/pam.d/sddm` is intact (`pacman -Qo /etc/pam.d/sddm` to confirm
  not overwritten; reinstall `sddm` if corrupted).
- **Session fails immediately** → the session command errored and SDDM returns
  to greeter. Look AFTER the auth line for the exec'd command:
  ```bash
  journalctl -b | grep -iE 'uwsm|session|exec|\.desktop'  # context
  journalctl --user -b -p err 2>/dev/null                  # user manager errors
  # run the session manually from a TTY to see its error directly:
  # (on a TTY, as the user)  uwsm start -e -D Hyprland hyprland.desktop
  ```
  A **missing/broken `hyprland-uwsm.desktop`** or a failing `Exec=` is the
  classic cause.
- **PATH/locale** problems: SDDM sets a minimal env; if the session command
  needs more (low-level), SDDM `[Users] DefaultPath=` and `[General] EnvironPath=`
  set PATH. A wrong locale can be set via `~/.config/environment.d/`.

### C. Autologin doesn't work
```bash
ls /etc/sddm.conf.d/   # check drop-ins
cat /etc/sddm.conf.d/*autologin* 2>/dev/null
```
- Needs BOTH `Session=` and `User=` in `[Autologin]`. Session filename must
  match exactly.

### D. Wrong/blank theme
```bash
systemctl status sddm
ls /usr/share/sddm/themes/
# try breeze to rule out a broken custom theme
```
- Ensure theme dir exists and is readable; font dependencies installed.

### E. "Failed to start" with dbus / logind error
```bash
systemctl status dbus
systemctl status systemd-logind
```
- SDDM depends on logind and D-Bus. If `systemd-logind` is masked/broken,
  session management fails.

### General diagnostic checklist
```bash
systemctl status sddm display-manager
journalctl -u sddm -e --no-pager
ls /usr/share/wayland-sessions/ /usr/share/xsessions/
pacman -Qo /etc/pam.d/sddm  2>/dev/null
loginctl list-sessions          # active sessions
```

## 10. Common gotchas

1. **Two display managers enabled** → `display-manager.service` alias conflict;
   enable only SDDM.
2. **Wayland greeter vs X11 greeter**: if the UI is blank/black, try
   `Compositor=weston` or reinstall `sddm-greeter-qt6`. For NVIDIA ensure GBM.
3. **Session name mismatch** in `[Autologin] Session=` — must equal the
   `.desktop` filename (`hyprland-uwsm`).
4. **Missing session `.desktop`** → greeter won't list the session; reinstall
   the package that ships it, then `omarchy refresh sddm`.
5. **PAM auth fails but TTY works** → `/etc/pam.d/sddm` issue; check/reinstall.
6. **Login immediately returns to greeter** → session exec failed; test the
   session command from a TTY to capture the real error.
7. **SDDM puts text on the wrong console** → VT issues; check `systemctl start sddm`
   targets VT7; a crash can leave it elsewhere.
8. **Theme fonts missing** → nerd-font/icon glyph boxes; install the theme's
   required font.
9. Config changes: **restart sddm** to apply (`systemctl restart sddm`) since
   SDDM reads config at startup (except themes which web-UIs reload).

## 11. Safety rules

- **Back up config** before editing: `cp -a /etc/sddm.conf /etc/sddm.conf.bak`
  and copy drop-ins too (or use `cp -a /etc/sddm.conf.d`).
- Use **drop-ins** (`/etc/sddm.conf.d/*.conf`) rather than editing
  `/etc/sddm.conf` so package updates don't silently override your settings.
- If you get locked out of the graphical UI, **switch to a TTY**
  (`Ctrl+Alt+F2`), and from there either fix config or
  `systemctl stop sddm` to get a text login.
- **Never edit `/etc/sddm.conf` directly if a drop-in already sets the same
  key** — the drop-in wins; remove/override the drop-in instead.
- Do not run `systemctl disable sddm` if you intend to keep graphical login —
  that's the enable mechanism, not a "safe" toggle.

## Example requests

- "Login screen is black" → check greeter/Wayland compositor, NVIDIA GBM, sddm logs, try `weston`.
- "I type my password, it logs back to login" → PAM + session exec; test TTY/su; check `hyprland-uwsm.desktop`.
- "The session doesn't appear in the menu" → verify `/usr/share/wayland-sessions/`.
- "Autologin not working" → check `[Autologin] Session=` + `User=` and session filename.
- "Theme is broken/ugly" → set `Current=breeze`, install fonts, verify theme dir.
- "SDDM won't start at boot" → `systemctl enable sddm`, check conflicting DMs, journal.
