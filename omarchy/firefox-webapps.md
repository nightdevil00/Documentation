# Firefox Webapps for Arch (`omarchy-launch-firefox-webapp`)

Run any website as a near-borderless app window using a **Firefox-based browser** —
a `chromium --app=URL` equivalent for Firefox / Zen / LibreWolf / Waterfox / Floorp.

No Omarchy required. Plain Arch + bash is enough.

## How it works

```
omarchy-launch-firefox-webapp [--browser zen] https://youtube.com/
```

1. Normalizes the URL (`youtube.com` → `https://youtube.com`, rejects
   `javascript:`/`file:`/`data:` and whitespace).
2. Derives a stable 8-char app id from the URL (`md5(url)[:8]`).
3. Creates an isolated profile at `~/.mozilla/<flavor>-ssb/<id>/` with a
   `chrome/userChrome.css` that hides the nav-bar + tab bar.
4. Launches (Mint Web App Manager parity: `--no-remote` forces a separate
   instance so the URL can't leak into your already-running main Firefox):
   ```
   firefox --class=FFWebApp-<id> --name=FFWebApp-<id> \
     --profile ~/.mozilla/firefox-ssb/<id> --no-remote \
     --new-window https://youtube.com/
   ```
   (`setsid uwsm-app -- …` is used when `uwsm-app` exists, like Omarchy does.)
5. The `--class` value doubles as `StartupWMClass` in the `.desktop` file, so the
   launcher, taskbar, and `omarchy-launch-or-focus`-style focus scripts see one app.

## Requirements

- Arch Linux, `bash`, and **one** of: `md5sum` (coreutils) or `python3`
- A Firefox-based browser (any, mix freely):
  | Flavor | Arch package | Binary | Profile base |
  |---|---|---|---|
  | `firefox` | `sudo pacman -S firefox` | `firefox` | `~/.mozilla/firefox-ssb/` |
  | `zen` | AUR `zen-browser-bin` | `zen-browser` | `~/.mozilla/zen-ssb/` |
  | `librewolf` | AUR/community `librewolf` | `librewolf` | `~/.mozilla/librewolf-ssb/` |
  | `waterfox` | AUR `waterfox` | `waterfox` | `~/.mozilla/waterfox-ssb/` |
  | `floorp` | AUR `floorp` | `floorp` | `~/.mozilla/floorp-ssb/` |
- Optional: `xdg-utils` (flavor auto-detect), `desktop-file-utils`
  (`update-desktop-database`), `uwsm-app` (Hyprland/UWSM scope)

## Install

```bash
cd ~/firefox-webapp-test
bash install.sh                  # -> ~/.local/bin (default)
bash install.sh --bindir ~/bin   # custom dir
sudo bash install.sh --system    # -> /usr/local/bin
bash install.sh --dry-run        # preview only
bash install.sh --uninstall      # remove
```

This copies **both** `omarchy-launch-firefox-webapp` and `webapp_lib.sh`
(they must stay in the same directory) and verifies with `DRY_RUN=1`.

If `~/.local/bin` is not on `PATH`, add:
```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Usage

```bash
omarchy-launch-firefox-webapp "https://youtube.com/"
omarchy-launch-firefox-webapp --browser zen "https://youtube.com/"
omarchy-launch-firefox-webapp -b librewolf "https://x.com/" --private-window
FIREFOX_FLAVOR=zen omarchy-launch-firefox-webapp "https://youtube.com/"
FIREFOX_BIN=/opt/custom/firefox omarchy-launch-firefox-webapp --browser zen <url>
DRY_RUN=1 omarchy-launch-firefox-webapp --browser zen "https://youtube.com/"
```

Env vars: `FIREFOX_FLAVOR`, `FIREFOX_BIN`, `FIREFOX_SSB_BASE`, `DRY_RUN=1`.

## Make a launcher (no Omarchy needed)

Create `~/.local/share/applications/YouTube-FF.desktop`:

```ini
[Desktop Entry]
Version=1.0
Name=YouTube-FF
Comment=YouTube (Firefox webapp)
Exec=omarchy-launch-firefox-webapp "https://youtube.com/"
Terminal=false
Type=Application
Icon=youtube
StartupNotify=true
StartupWMClass=FFWebApp-7207dff0
```

Find the right `StartupWMClass` with:
```bash
DRY_RUN=1 omarchy-launch-firefox-webapp "https://youtube.com/" | grep WM_CLASS
DRY_RUN=1 omarchy-launch-firefox-webapp --browser zen "https://youtube.com/" | grep WM_CLASS
```

For Zen replace `Exec` / `StartupWMClass`:
```ini
Exec=omarchy-launch-firefox-webapp --browser zen "https://youtube.com/"
StartupWMClass=ZenWebApp-7207dff0
```

Then:
```bash
update-desktop-database ~/.local/share/applications
gtk-launch YouTube-FF   # test
```

On Omarchy you can generate the same file with:
```bash
omarchy-webapp-install "YouTube-FF" "https://youtube.com/" "youtube" \
  'omarchy-launch-firefox-webapp "https://youtube.com/"'
```

## Window manager examples

Hyprland (`~/.config/hypr/bindings.lua` style):
```lua
o.bind("SUPER + SHIFT + Y", "YouTube-FF", { launch = 'omarchy-launch-firefox-webapp "https://youtube.com/"' })
```

Focus-or-launch (pattern = WM_CLASS):
```bash
omarchy-launch-or-focus "FFWebApp-7207dff0" 'omarchy-launch-firefox-webapp "https://youtube.com/"'
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Click does nothing | `Exec` binary not on `PATH`: run `which omarchy-launch-firefox-webapp`; reinstall via `bash install.sh`; `update-desktop-database ~/.local/share/applications` |
| `webapp_lib.sh not found` | Launcher + lib must be in the **same** dir — `install.sh` handles this; don't copy the launcher alone |
| Two Firefox windows share profile error | Each URL gets its own profile; don't point `FIREFOX_SSB_BASE` at your main profile |
| No app-like UI (tabs still visible) | `user.js` sets `toolkit.legacyUserProfileCustomizations.stylesheets=true`; profile is created on first run — restart the webapp once |
| Wrong browser opens | `--browser` > `FIREFOX_FLAVOR` > xdg default > `firefox`; check with `DRY_RUN=1 … \| grep -E 'FLAVOR|BINARY'` |
| `zen-browser: command not found` | Install AUR `zen-browser-bin`, or set `FIREFOX_BIN=/opt/zen-browser/zen` |

## Uninstall

```bash
bash install.sh --uninstall
rm -rf ~/.mozilla/firefox-ssb ~/.mozilla/zen-ssb   # profiles (optional)
rm ~/.local/share/applications/YouTube-FF.desktop  # launchers you made
update-desktop-database ~/.local/share/applications
```

## Notes / limits

- This is a **profile + `--class` + `userChrome.css` shim**, not Mozilla's native
  Taskbar-Tabs PWA (Windows-only in FF156, Linux behind
  `browser.taskbarTabs.enabled`). It covers ~80% of `chromium --app`.
- For full PWA fidelity on Arch, see `firefoxpwa` (`sudo pacman -S firefoxpwa` +
  the PWAsForFirefox extension) — heavier, but real isolated runtime.
- Tests: `bash test_webapp.sh` (66 checks, no dependencies).
