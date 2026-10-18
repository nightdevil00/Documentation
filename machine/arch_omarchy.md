# Layering Omarchy on an existing Arch install

**Goal:** put Omarchy (DHH's opinionated Arch desktop — Hyprland, theming, apps,
tooling) on top of an *already bootable* Arch Linux system, without the Omarchy
ISO reinstalling your disk. Covers the common base of **btrfs + Limine +
Snapper snapshots + Hyprland**, and also plain **arch minimal** as long as the
machine boots.

**Verified against:** Omarchy **4.0.5-1**, stable channel
(`https://pkgs.omarchy.org/stable/x86_64/`), on 2026-10-18.
Reference machine: Lenovo laptop, i7-10750H / GTX 1650 Ti, LUKS + btrfs
(`@`, `@home`, `@snapshots` mounted at `/.snapshots`), Limine 12.9.3,
pre-existing Hyprland + SDDM + NetworkManager, user `mihai` in `wheel`.

**Tooling:** [`install.sh`](./install.sh) automates every phase below.

---

## 1. What "layering" means

The Omarchy ISO does two things: (a) partition/mirror the disk, (b) run a
sequence of *target-side configuration phases* inside the installed system.
Layering = replicate phase group (b) on a system you already have.

The official phase list lives in the ISO orchestrator:
`omarchy-iso/configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py`
(`configure_pacman`, `install_packages`, `finalize_system` →
`omarchy-apply-system`, `configure_login`, `finalize_limine_boot`,
`validate_boot`, …).

Two categories of steps exist:

| Where it runs | Executed by | Examples |
|---|---|---|
| **In `omarchy-apply-system`** | one command, idempotent | themes, PAM, ssh keepalive, docker, snapper config, service enablement, ufw, hardware detection, SDDM PAM, pacman hooks, udev, localdb |
| **ISO-only (you must do these)** | manual / `install.sh` | pacman repo + keyring bootstrap, package install, user creation, skel replay, user provisioning, SDDM login/autologin state, **`/etc/kernel/cmdline`**, **`/etc/default/limine`**, native-messaging hosts, verification |

The two **bold** files are the dangerous omission: they are the *only* sources
the boot tooling reads for the kernel command line. Without them, Omarchy
regenerates the UKI and `limine.conf` with **cosmetic parameters only — no
`root=`, no `rd.luks.*`, no `rootflags`** — and the machine will not boot.
See §5 gotcha G4.

---

## 2. Prerequisites

- Bootable Arch Linux (`/etc/arch-release`), root access, network (HTTPS to
  `pkgs.omarchy.org`).
- A non-root user in `wheel` (or `install.sh` will create one; it prompts for
  a password).
- **btrfs strongly recommended.** Omarchy's whole recovery story (Snapper +
  Limine snapshot boot menu) assumes btrfs. The script still runs on
  ext4/xfs, but the snapshot phases are skipped and `omarchy`'s snapper
  template (`FSTYPE="btrfs"`) won't match.
- No need to pre-install anything from Omarchy's stack: `omarchy` **depends on**
  `limine`, `limine-mkinitcpio-hook`, `limine-snapper-sync`, `snapper`,
  `hyprland`, `sddm`, `uwsm`, `plymouth` — they come with `pacman -S omarchy`.
- `sudo` must be installed (several omarchy scripts shell out to it).
- Recommended before you start: at least one working snapshot or backup of
  `/` — §6.

**If you are *not* currently booting Limine** (GRUB / systemd-boot): layering
still works and does **not** touch your EFI boot order or NVRAM. You get the
Omarchy desktop; you just don't get the Limine snapshot boot menu (the boot
phase is skipped with a warning). Switching the active bootloader to Limine is
a deliberate, separate step.

---

## 3. The process

`install.sh` runs these phases in order; each is listed with the manual
equivalent. All commands run as root unless marked *as user*.

### Phase 0 — pre-layer snapshots (rollback safety)

```bash
mkdir -p /.snapshots
btrfs subvolume snapshot -r /   /.snapshots/pre-omarchy-layer-$(date +%Y%m%d-%H%M%S)
btrfs subvolume snapshot -r /home /.snapshots/pre-omarchy-layer-home-$(date +%Y%m%d-%H%M%S)
```

Read-only snapshots of `@` and `@home`. If `/.snapshots` is your snapper
`@snapshots` mount (common), they land there; if it doesn't exist yet, a plain
directory inside `@` is fine (per-snapshot entries are still subvolumes).
`--no-snapshot` skips this.

### Phase 1 — pacman repository + keyring (chicken-and-egg bootstrap)

Omarchy packages are signed by the Omarchy key, but the key lives in a package
from the Omarchy repo. Break the loop manually *before* trusting anything:

1. Add the repo to `/etc/pacman.conf` (your existing file is preserved; the
   section is inserted **before `[core]`** so omarchy-pinned versions win):

   ```ini
   [omarchy]
   Server = https://pkgs.omarchy.org/stable/$arch
   ```

   `SigLevel = Required DatabaseOptional` (stock Arch) is assumed: the
   *database* signature is optional, so `pacman -Sy` works before the keyring
   exists; *package* signatures are verified after step 2.

2. Fetch the keyring package directly (directory listings 404 — go through the
   package DB):

   ```bash
   curl -fsSL https://pkgs.omarchy.org/stable/x86_64/omarchy.db -o /tmp/omarchy.db
   PKG=$(tar -tf /tmp/omarchy.db | grep -oE '^omarchy-keyring-[^/]+' | head -1)   # e.g. omarchy-keyring-20251027-1
   curl -fsSL "https://pkgs.omarchy.org/stable/x86_64/$PKG.pkg.tar.zst" -o /tmp/kr.pkg.tar.zst
   bsdtar -xf /tmp/kr.pkg.tar.zst -C /tmp/kr usr/share/pacman/keyrings
   cp -a /tmp/kr/usr/share/pacman/keyrings/omarchy* /usr/share/pacman/keyrings/
   pacman-key --populate omarchy
   ```

   > Do **not** use `https://pkgs.omarchy.org/omarchy.gpg` — it is not a valid
   > keyring file. The files must come from inside the keyring package.

3. Register the package properly in pacman's DB (overwrites the extracted
   files with package ownership):

   ```bash
   pacman -Sy
   pacman -S --needed --overwrite '/usr/share/pacman/keyrings/*' omarchy-keyring
   ```

### Phase 2 — packages

```bash
pacman -S --needed omarchy omarchy-settings
mapfile -t PKGS < <(grep -vE '^\s*(#|$)' /usr/share/omarchy/install/omarchy-base.packages)
# pre-filter packages whose "Conflicts With" is already installed (see below), then:
pacman -S --needed "${PKGS[@]}"     # script falls back to per-package install on error
```

- The base list lives at **`/usr/share/omarchy/install/omarchy-base.packages`**
  (not under `default/`) and is the same list the ISO pacstraps.
- **Pre-filter hard conflicts (G16):** `mise-bin` (in the list) declares
  `Conflicts With: mise` — a system that already has `mise` aborts the *entire*
  bulk transaction, blocking all 146 innocent packages. Ask `pacman -Si` per
  not-yet-installed package and skip anything whose conflicting counterpart is
  already present: `skipping packages already provided otherwise: mise-bin→mise`.
- **No `pacman -Suu`.** Omarchy's own `omarchy-reinstall-pkgs` runs
  `pacman -Syyuu` to *downgrade* to stable pins — that's the right tool for
  purifying an Omarchy install, but wrong for layering onto your working
  system. The script skips it. (`--omarchy-mirrors` opts into
  `omarchy-refresh-pacman <channel>`, which *does* run `-Syyuu`.)
- To put Omarchy's dedicated mirrors under `[core]/[extra]` too:
  `omarchy-refresh-pacman stable|rc|edge` (backs up both files first).

### Phase 3 — system configuration

```bash
# snapper pre-seed — see gotcha G2
mkdir -p /etc/snapper/configs && : > /etc/snapper/configs/root   # only if missing

omarchy-apply-system --install-user <user> --first-install
systemctl restart snapperd          # see gotcha G3
snapper -c root list                # must list config 'root'
```

Repair a broken `/etc/vconsole.conf` — archinstall writes the literal
`KEYMAP=(unset)` — the same way the ISO's `keyboard.py` does
(`systemd-firstboot --keymap`, preserving any `FONT=` line):

```bash
grep -E '^KEYMAP=(\(unset\))?$' /etc/vconsole.conf && \
  systemd-firstboot --keymap=us --force   # script picks the keymap from localectl, fallback us
```

Why it matters (G17): mkinitcpio's keymap hook fails with
`loadkeys: Unable to open file: unset` on every UKI build, and omarchy's
`default/hypr/input.lua` reads `XKBLAYOUT` from this file.

`omarchy-apply-system` (as root) chains, in order:

1. `install/config/all.sh` — theme-system, browser-policy, lockout-limit,
   lockscreen-PAM, powerprofiles shebang, ssh command-path + keepalive,
   docker, **snapper** (installs Omarchy retention template: 5 snapshots,
   no timeline), **enable-services**
   (`cups avahi-daemon linux-modules-cleanup docker.socket systemd-resolved
   NetworkManager power-profiles-daemon sddm systemd-oomd` + **mask**
   `NetworkManager-wait-online`), **firewall** (ufw defaults, LocalSend
   53317, docker-DNS rules, `ufw-docker`, `ENABLED=yes` + enable ufw).
2. `omarchy-apply-hardware` — hardware detection/quirks (nvidia, asus,
   framework, apple, …), harmless no-ops on unmatched hardware.
3. `install/login/all.sh` — SDDM PAM keyring-line removal.
4. `install/post-install/all.sh` — pacman hooks/config, udev, localdb.

Everything is idempotent; re-running is safe. It exits non-zero on the first
failing script (`set -e`), which is why snapper must be pre-seeded.

### Phase 4 — user

```bash
# new user (only if the login doesn't exist):
useradd -m -G wheel -s /bin/bash <user> && passwd <user>

# existing user: back up, then replay /etc/skel (destructive, omarchy's own
# method — same as what `omarchy-reinstall-configs` does):
tar -czf /root/omarchy-home-prelayer-<ts>.tar.gz -C ~<user> \
    --exclude='.config/chromium' --exclude='.config/google-chrome*' \
    --exclude='.config/BraveSoftware' --exclude='.config/microsoft-edge*' \
    .config .bashrc .bash_profile .profile
cp -af /etc/skel/. ~<user>/ && chown -R <user>:<user> ~<user>

# finalize — MUST run as the user, never as root:
sudo -u <user> env HOME=~<user> OMARCHY_PATH=/usr/share/omarchy \
     XDG_RUNTIME_DIR=/run/user/$(id -u <user>) \
     OMARCHY_SETUP_CONTEXT=provision-owner \
     omarchy-provision-user --first-install
```

- `omarchy-provision-user` refuses to run as root (exit 1).
- `OMARCHY_SETUP_CONTEXT=provision-owner` selects the **network** Node install;
  without it the script looks for a bundled Node tarball under `/opt/packages`
  (ISO-only) and exits 1.
- It runs `install/user/all.sh`: theme, **chromium native hosts**
  (`omarchy-install-chromium-copy-url`, `-ytdlp`), git, xcompose, mise-work,
  gnome-keyring default, mise (node), hardware user-fixes.
- Pass `OMARCHY_PATH=/usr/share/omarchy` explicitly: `sudo -u` is a
  non-login shell and never sources `/etc/profile.d/omarchy.sh` (G1).

### Phase 5 — SDDM login state (ISO `configure_login` equivalent)

```bash
# greeter defaults:
printf '[Theme]\nCurrent=omarchy\n\n[Users]\nRememberLastUser=true\nRememberLastSession=true\n' \
  > /etc/sddm.conf.d/99-omarchy-login.conf

# last-user state:
install -d -m 755 /var/lib/sddm
printf '[Last]\nSession=omarchy.desktop\nUser=%s\n' <user> > /var/lib/sddm/state.conf
chown -R sddm:sddm /var/lib/sddm

# autologin — ONLY for encrypted installs (LUKS prompt is the auth boundary).
# findmnt appends the btrfs subvol as "[/@]" — strip it or every probe fails (G14);
# the lsblk ancestor walk also catches LVM-on-LUKS:
ROOT_SRC=$(findmnt -no SOURCE / | sed 's/\[.*//')
lsblk -sno TYPE "$ROOT_SRC" | grep -qx crypt && \
  printf '[Autologin]\nUser=%s\nSession=omarchy.desktop\n' <user> > /etc/sddm.conf.d/autologin.conf

rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf   # never autologin on tty1
```

The session is **`omarchy.desktop`** (from `omarchy-settings`, installed into
`/usr/local/share/wayland-sessions/`): `uwsm start … Hyprland`.

### Phase 6 — user refreshes (all *as user*)

```bash
omarchy-refresh-applications          # .desktop launchers + mise wrappers
omarchy-install-chromium-copy-url     # native-messaging hosts (safe to re-run)
omarchy-install-chromium-ytdlp
omarchy-refresh-plymouth              # MUST be as user; `sudo omarchy-plymouth-set` fails
omarchy-nvim-refresh                  # if present (else omarchy-nvim-setup --force)
```

### Phase 7 — boot integration (the part the ISO does and apply-system doesn't)

```bash
# 0. move ESP copies that shadow /boot/limine.conf (G15) — the limine package
#    drops its own default config next to the binary on upgrade:
for c in /boot/EFI/limine/limine.conf /boot/efi/EFI/limine/limine.conf; do
  [ -f "$c" ] && mv "$c" "$c.omarchy-conflict-$(date +%Y%m%d-%H%M%S)"
done

# 1. kernel cmdline — source for BOTH /etc/default/limine and the UKI embed:
[[ -f /etc/kernel/cmdline ]] || \
  sed -E 's#rootflags=subvol=/*#rootflags=subvol=/#' /proc/cmdline > /etc/kernel/cmdline
#    (normalize rootflags=subvol=@ → subvol=/@ so limine-snapper-sync is satisfied)

# 2. /etc/default/limine — KERNEL_CMDLINE wrapper:
sed "s|@@CMDLINE@@|$(cat /etc/kernel/cmdline)|" \
  /usr/share/omarchy/default/limine/default.conf > /etc/default/limine

# 3. rebuild UKI + regenerate /boot/limine.conf + snapshot menu:
limine-mkinitcpio
omarchy-refresh-limine                 # template conf + limine-update + limine-snapper-sync

# 4. bootable baseline snapshot:
snapper -c root create -d "omarchy layer baseline"
limine-snapper-sync
```

Why each file matters:

- `limine-entry-tool --get-cmdline <kernel>` composes
  `/etc/kernel/cmdline` (base) + `KERNEL_CMDLINE[default]` from
  `/etc/default/limine` + `/etc/limine-entry-tool.d/*.conf` (Omarchy extras:
  `quiet splash loglevel=0 … initramfs_async=0 systemd.tty.term.console=dumb`).
  The result is written **both** into `limine.conf`'s `cmdline:` **and** into
  the UKI's `.cmdline` PE section (via `limine-mkinitcpio` → `ukify --cmdline`).
- If `/etc/kernel/cmdline` and `/etc/default/limine` are missing (ISO-less
  install), the composed cmdline is *extras only* → unbootable (G4).
- `limine-snapper-sync` writes the `//Snapshots` menu into `limine.conf`,
  saves a per-snapshot UKI copy under
  `/boot/<machine-id>/limine_history/`, and caches entries in **two**
  manifests (`…/limine_history/snapshots.json` **and**
  `/var/cache/boot/<machine-id>/lss/snapshots.json`) — both must be deleted to
  force a rebuild (G5).
- Hashes in `limine.conf` paths (`path: …#<128 hex>`) are **blake2b-512**
  (`b2sum`); the history *filename* suffix `…_sha256_<64 hex>` is SHA-256 of
  the same file. Different algorithms, both correct — don't chase this (G7).

Cosmetic `limine-mkinitcpio` output you can ignore: `consolefont: no font
found in configuration` (no `FONT=` line in `vconsole.conf` — same on ISO
machines whose installer skipped it) and `Possibly missing firmware for
module: xhci_pci_renesas / qat_6xxx` (hardware-dependent, non-fatal).

### Phase 8 — verification

`install.sh` prints a PASS/FAIL table for: `omarchy version`, channel,
`pacman -Qkk omarchy` → `0 altered files`, services (active: sddm,
NetworkManager, snapperd; enabled: + ufw, cups, docker.socket,
snapper-cleanup.timer, limine-snapper-sync), snapper `root` config,
`root=` present in `/etc/kernel/cmdline` + composed cmdline + `limine.conf`,
SDDM autologin matches encryption state, `omarchy.desktop` present, **zero
conflicting limine configs on the ESP**, sane `vconsole.conf` keymap, native
hosts pointing at `/usr/share/omarchy`, user in `wheel`.

Manual spot-checks:

```bash
omarchy version                                  # 4.0.5-1
OMARCHY_PATH=/usr/share/omarchy omarchy-channel-current   # stable
pacman -Qkk omarchy | tail -1                    # 0 altered files
limine-entry-tool --get-cmdline linux --no-mutex --no-hooks | tail -1   # contains root=
grep -E '^ *cmdline:' /boot/limine.conf          # contains root= and rootflags=
snapper -c root list
systemctl status sddm
```

---

## 4. Script usage

```bash
sudo ./install.sh [options] <username>

  -c, --channel <stable|rc|edge>   Omarchy channel (default: stable)
  --no-snapshot                    skip the pre-layer btrfs snapshots
  --no-skel-replay                 don't replay /etc/skel over an existing $HOME
  --omarchy-mirrors                run `omarchy-refresh-pacman <channel>`
                                   (switches [core]/[extra] to Omarchy mirrors;
                                    runs pacman -Syyuu → DOWNGRADES newer pkgs)
  -h, --help                       usage

<username> defaults to $SUDO_USER when run via sudo.
Exit code 0 = all verification checks passed; 1 = at least one FAIL (details
in the table) or a phase errored (full log: /var/log/omarchy-layer-install.log).
```

Typical:

```bash
sudo ./install.sh mihai                          # layer, keep my mirrors
sudo ./install.sh --no-skel-replay mihai         # keep my ~/.config as-is
sudo ./install.sh -c edge mihai                  # edge channel
```

Re-runnable: every phase is idempotent (skel replay is the one destructive
step — it makes a tar backup first, or use `--no-skel-replay`). Verified by
running the script twice back-to-back on the reference machine: second run
was a clean no-op pass with 25/25 verification checks.

---

## 5. Gotchas (all hit in the field — don't relearn these)

| # | Symptom | Cause | Fix |
|---|---|---|---|
| G1 | Native-messaging JSONs, desktop files, configs point into a source checkout (e.g. `~/Downloads/…`); `omarchy channel-current` → `dev` | `OMARCHY_PATH` exported to a non-standard tree poisons every script that expands `$OMARCHY_PATH` | Never export `OMARCHY_PATH` outside development; `unset OMARCHY_PATH` (scripts default to `/usr/share/omarchy` via `env-bootstrap`; `/etc/profile.d/omarchy.sh` sets it for login shells). `sudo -u` sessions need it passed explicitly. Fix polluted files: re-run `omarchy-install-chromium-copy-url` / `-ytdlp` with correct path. |
| G2 | `apply-system` dies at snapper: `Creating config failed (creating btrfs subvolume .snapshots failed since it already exists)` | `snapper create-config` insists on creating `/.snapshots` itself; any pre-existing mount/dir (snapshots already set up) makes it fail, and `set -e` aborts the whole chain | Pre-create `/etc/snapper/configs/root` (even empty) — `snapper.sh` then skips `create-config` and installs Omarchy's template unconditionally |
| G3 | `snapper -c root list` → "config does not exist" although the file exists; `--no-dbus` works | `snapperd` started while `/etc/snapper/configs/` was empty and never re-scans | `systemctl restart snapperd` **after** the config file is final |
| G4 | After refresh, `limine.conf` and the UKI `.cmdline` contain no `root=`/`rd.luks`/`rootflags` → **next reboot fails to boot** | `limine-entry-tool` reads `/etc/kernel/cmdline` + `/etc/default/limine`; the ISO writes both, `omarchy-apply-system` does not — an ISO-less layer misses them | Create both files (Phase 7), rebuild UKI, verify `root=` in composed cmdline **and** in `grep -a root= /boot/EFI/Linux/*.efi` |
| G5 | Snapshot menu entries boot-fail or show stale cmdline | `limine-snapper-sync` caches entries + cmdline in `snapshots.json` manifests | Delete `/boot/<mid>/limine_history/snapshots.json*` **and** `/var/cache/boot/<mid>/lss/snapshots.json*`, re-run sync |
| G6 | `Missing 'rootflags=subvol=/@' in the kernel cmdline` warning from sync | sync expects the slashed form; `/proc/cmdline` often has `rootflags=subvol=@` | Normalize when writing `/etc/kernel/cmdline` (`sed -E 's#rootflags=subvol=/*#rootflags=subvol=/#'`) |
| G7 | `#<128-hex>` in `limine.conf` path doesn't match `sha256sum` of the UKI | Limine entry hashes are **blake2b-512**; the `…_sha256_` filename in `limine_history/` is SHA-256 | Verify with `b2sum <uki>`; both can be correct simultaneously |
| G8 | `omarchy-provision-user` exit 1: "run … as the user being configured, not as root" | by design | `sudo -u <user> …` |
| G9 | `omarchy-provision-user` exit 1 looking for `/opt/packages` Node tarball | default setup context assumes the ISO bundle | `OMARCHY_SETUP_CONTEXT=provision-owner` → network install |
| G10 | `sudo omarchy-plymouth-set` fails; works as user | script is written for user + internal sudo escalation | run `omarchy-refresh-plymouth` as the user |
| G11 | `omarchy commands --check` reports "Missing metadata summary: omarchy-nvim-refresh/setup" | cosmetic: those two scripts lack the `# omarchy:summary=` header; `pacman -Qkk omarchy-nvim` = 0 altered | ignore |
| G12 | `snapper` snapshot created but no boot menu entry | sync only lists *snapper* snapshots (arbitrary `btrfs subvolume snapshot` dirs aren't snapper-managed) | create snapshots via `snapper -c root create` |
| G13 | Omarchy packages shadowed by `[core]/[extra]` versions | repo order in `pacman.conf` | keep `[omarchy]` **before** `[core]` |
| G14 | Encryption probe says "unencrypted" on a LUKS machine (script then *removes* autologin) | `findmnt -no SOURCE /` returns `/dev/mapper/root[/@]` — the `[/@]` subvol suffix makes `cryptsetup status` answer "inactive" and `lsblk`/`blkid` fail | strip first: `sed 's/\[.*//'`; detect via `lsblk -sno TYPE "$SRC" \| grep -qx crypt` (ancestor walk, covers LVM-on-LUKS too) |
| G15 | `limine-update` warns `Detected conflicting config: /boot/EFI/limine/limine.conf`; Omarchy theme / UKI entries / snapshot menu missing at boot although `/boot/limine.conf` is perfect | the **limine package upgrade** drops its own default `limine.conf` next to the ESP binary; Limine's search order prefers the same-directory copy and ignores `/boot/limine.conf` | move the ESP copy aside (`*.omarchy-conflict-<ts>` backup kept) — omarchy owns `/boot/limine.conf`; a later `limine` upgrade can re-drop it, so the verification check flags it again |
| G16 | Bulk `pacman -S` of the base list aborts: `unresolvable package conflicts detected` (and `--needed` retries look like 147 individual calls) | `mise-bin` (in the list) declares `Conflicts With: mise`; any installed conflicting package kills the *whole* transaction, blocking every unrelated package | pre-filter: for each not-installed package read `pacman -Si` → `Conflicts With` and skip if that counterpart is installed (`mise-bin→mise` — same tool, already present) |
| G17 | Every UKI build prints `loadkeys: Unable to open file: unset`; Hyprland keyboard layout silently falls back to `us` | archinstall-style `/etc/vconsole.conf` containing the literal `KEYMAP=(unset)` — mkinitcpio's keymap hook chokes, omarchy's `input.lua` finds no `XKBLAYOUT` | `systemd-firstboot --keymap=<map> --force` (re-append `FONT=` if present) — exactly what the ISO's `keyboard.py` does; keymap detection: localectl `VC Keymap` → `X11 Layout` → `us` |

---

## 6. Rollback

**Layers of safety, newest first:**

1. **Limine boot menu → "Snapshots"** — every snapper snapshot (including the
   `omarchy layer baseline` this process creates) boots as a full system.
   The entry carries the correct `rootflags=subvol=/@snapshots/<id>/snapshot`
   and a frozen UKI copy under `/boot/<machine-id>/limine_history/`.
2. **Pre-layer read-only snapshots** (Phase 0), if not snapper-managed:
   `/.snapshots/pre-omarchy-layer*` — boot any live USB, unlock LUKS, mount
   the root device, then swap subvolumes the classic btrfs way (rename current
   `@` aside, `btrfs subvolume create` a fresh `@`, `btrfs send/receive` or
   plain `cp -a` snapshot contents back, keep the old one around for safety).
   Practise this once before you need it — it's the one procedure no script
   can run for you while the system is mounted read-write under you.
3. **File backups made by the process**: `/etc/pacman.conf.bak.omarchy-*`,
   `/etc/snapper/configs/root.bak.omarchy-*`,
   `/root/omarchy-home-prelayer-*.tar.gz`, `/boot/limine.conf.bak`
   (plus `omarchy-refresh-pacman`'s own `.bak` files), and
   `/boot/EFI/limine/limine.conf.omarchy-conflict-*` — restore that one only
   if you abandon omarchy's `/boot/limine.conf` entirely.

**Coarse undo** (keeps your data, removes the layer):

```bash
pacman -Rns --noconfirm omarchy omarchy-settings omarchy-nvim \
       omarchy-hyprland-titlebars omarchy-themes-intros   # + orphan cleanup: pacman -Rns $(pacman -Qtdq)
systemctl disable sddm; rm -f /etc/sddm.conf.d/{99-omarchy-login,autologin}.conf
# restore pacman.conf / snapper config from the .bak.omarchy-* files
# your old Hyprland config: /root/omarchy-home-prelayer-*.tar.gz
```

---

## 7. Post-install notes

- **Reboot.** LUKS prompt first (encrypted installs), then autologin straight
  into the Omarchy desktop; unencrypted installs get the normal SDDM
  password screen.
- Channel switching later: `omarchy channel …` / `omarchy-refresh-pacman <ch>`;
  updates: `omarchy update` (or `pacman -Syu`).
- Omarchy's sudo model: narrow NOPASSWD rules in `/etc/sudoers.d/omarchy-*`
  for bar/menu commands; `%wheel ALL=(ALL:ALL) ALL` in `/etc/sudoers` (password
  prompt) — your own user-level NOPASSWD drop-in still wins.
- Locale/keymap are **not** touched (the ISO owns that phase). Omarchy's UI
  assumes `en_US.UTF-8`; set it yourself if different (`localegen`).
- Services are *enabled* but not started mid-install (except where ufw/sddm
  activate themselves) — reboot brings up the final state.
- Log: `/var/log/omarchy-layer-install.log` (script) and
  `/var/log/omarchy-install.log` (apply-system's own phase log — grep
  `Failed:` for the exact failing script).
