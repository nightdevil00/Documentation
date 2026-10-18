#!/usr/bin/env bash
#
# install.sh — layer Omarchy on top of an existing Arch Linux installation.
#
# Adds the Omarchy repository/keyring, installs the Omarchy package set,
# runs omarchy-apply-system, provisions the user, and completes the boot
# integration (kernel cmdline, UKI, Limine snapshot menu) that the Omarchy
# ISO normally does but apply-system does not.
#
# Designed for: btrfs + Limine + Snapper + Hyprland bases (the standard
# Omarchy-shaped stack) and plain arch minimal. Never touches partitioning,
# fstab, crypttab, locale, or EFI boot order.
#
# Verified against Omarchy 4.0.5 (stable). See arch_omarchy.md for the
# full write-up, gotcha table, and rollback procedures.
#
# Usage:
#   sudo ./install.sh [options] <username>
#
# Options:
#   -c, --channel <stable|rc|edge>  Omarchy channel (default: stable)
#   --no-snapshot                   skip pre-layer read-only btrfs snapshots
#   --no-skel-replay                keep an existing $HOME config as-is
#   --omarchy-mirrors               switch [core]/[extra] to Omarchy mirrors
#                                   via omarchy-refresh-pacman (runs pacman
#                                   -Syyuu → DOWGRADES packages newer than pins)
#   -h, --help                      show usage
#
# <username> defaults to $SUDO_USER. Exit 0 = all verification checks passed.

set -Eeuo pipefail

CHANNEL=stable
TARGET_USER="${SUDO_USER:-}"
NO_SNAPSHOT=0
NO_SKEL=0
OMARCHY_MIRRORS=0
TS="$(date +%Y%m%d-%H%M%S)"
LOG=/var/log/omarchy-layer-install.log
OMARCHY_SHARE=/usr/share/omarchy
# epilogue pointers — set only when the artifact is actually created this run
ROLLBACK_SNAP="" PACMAN_BAK="" SNAPPER_BAK="" HOME_BAK="" CONFLICT_MOVED="" BASELINE_OK=0

usage() { sed -n '3,29p' "$0" | sed 's/^# \{0,1\}//'; }

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }
ok()   { echo "      $*"; }
warn() { echo "  WARNING: $*" >&2; }

while (($#)); do
  case "$1" in
    -c|--channel)    CHANNEL="${2:-}"; shift 2 ;;
    --no-snapshot)   NO_SNAPSHOT=1; shift ;;
    --no-skel-replay) NO_SKEL=1; shift ;;
    --omarchy-mirrors) OMARCHY_MIRRORS=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    -*)              usage >&2; exit 1 ;;
    *)               TARGET_USER="$1"; shift ;;
  esac
done

[[ $CHANNEL == stable || $CHANNEL == rc || $CHANNEL == edge ]] \
  || die "invalid channel '$CHANNEL' (stable, rc, edge)"
[[ -n $TARGET_USER && $TARGET_USER != root ]] \
  || die "no target user given (usage: sudo ./install.sh <username>)"

# ---------------------------------------------------------------- preflight --
(( EUID == 0 )) || die "run as root: sudo ./install.sh $TARGET_USER"
[[ -f /etc/arch-release ]] || die "this does not look like Arch Linux"

# Never inherit a development checkout path: every omarchy script expands
# $OMARCHY_PATH, and a wrong value poisons configs, native-messaging hosts
# and the channel report (arch_omarchy.md gotcha G1).
unset OMARCHY_PATH OMARCHY_INSTALL OMARCHY_INSTALL_USER || true

for c in curl bsdtar pacman-key sudo; do
  command -v "$c" >/dev/null || die "'$c' is required"
done

exec > >(tee -a "$LOG") 2>&1
echo "==== omarchy layer install: $TS (channel: $CHANNEL, user: $TARGET_USER) ===="
trap 'echo; echo "ERROR: install.sh failed near line $LINENO — full log: $LOG" >&2' ERR

REPO_URL="https://pkgs.omarchy.org/$CHANNEL/$(uname -m)"

# ------------------------------------------------------------ phase 0: safety
step "Phase 0 — pre-layer btrfs snapshots"
if (( NO_SNAPSHOT )); then
  ok "skipped (--no-snapshot)"
elif [[ $(findmnt -no FSTYPE /) == btrfs ]]; then
  mkdir -p /.snapshots
  if btrfs subvolume snapshot -r / "/.snapshots/pre-omarchy-layer-$TS"; then
    ROLLBACK_SNAP="/.snapshots/pre-omarchy-layer-$TS"
    ok "/ → $ROLLBACK_SNAP (read-only)"
  else
    warn "could not snapshot / (different filesystem for /.snapshots?) — continuing without safety snapshot"
  fi
  if findmnt /home >/dev/null 2>&1 && [[ $(findmnt -no FSTYPE /home) == btrfs ]]; then
    btrfs subvolume snapshot -r /home "/.snapshots/pre-omarchy-layer-home-$TS" \
      && ok "/home → /.snapshots/pre-omarchy-layer-home-$TS (read-only)" \
      || warn "could not snapshot /home (busy?) — continuing"
  fi
else
  warn "root is $(findmnt -no FSTYPE /), not btrfs — skipping snapshots (Omarchy's snapshot boot menu assumes btrfs)"
fi

# ------------------------------------------------------- phase 1: repo + keys
step "Phase 1 — Omarchy repository + package keyring"
REPO_CONF_URL="$REPO_URL"

if grep -qE '^\[omarchy\]' /etc/pacman.conf; then
  ok "[omarchy] repo already present in /etc/pacman.conf"
else
  PACMAN_BAK="/etc/pacman.conf.bak.omarchy-$TS"
  cp -a /etc/pacman.conf "$PACMAN_BAK"
  tmp=$(mktemp)
  awk -v ch="$CHANNEL" '
    BEGIN { done = 0 }
    /^\[core\]/ && done == 0 {
      print "[omarchy]"
      print "Server = https://pkgs.omarchy.org/" ch "/" "$" "arch"
      print ""
      done = 1
    }
    { print }
    END {
      if (done == 0) {
        print ""
        print "[omarchy]"
        print "Server = https://pkgs.omarchy.org/" ch "/" "$" "arch"
      }
    }' /etc/pacman.conf >"$tmp"
  install -m 644 "$tmp" /etc/pacman.conf
  rm -f "$tmp"
  ok "[omarchy] section inserted before [core] (backup: $PACMAN_BAK)"
fi

# Keyring bootstrap: Omarchy packages are signed by a key that ships inside a
# package from the Omarchy repo — install the keyring manually first.
if [[ -f /usr/share/pacman/keyrings/omarchy.gpg ]] \
   && pacman-key --list-keys 2>/dev/null | grep -qi omarchy; then
  ok "omarchy keyring already populated"
else
  work=$(mktemp -d)
  db="$work/omarchy.db"
  curl -fsSL --retry 3 "$REPO_CONF_URL/omarchy.db" -o "$db" \
    || curl -fsSL --retry 3 "$REPO_CONF_URL/omarchy-$CHANNEL.db" -o "$db" \
    || die "cannot fetch the omarchy package DB from $REPO_CONF_URL"
  pkgdir=$(tar -tf "$db" | grep -oE '^omarchy-keyring-[^/]+' | head -1)
  [[ -n $pkgdir ]] || die "omarchy-keyring not found in package DB"
  pkgfile=""
  for ext in pkg.tar.zst pkg.tar.xz pkg.tar.gz; do
    if curl -fsSL --retry 3 "$REPO_CONF_URL/$pkgdir.$ext" -o "$work/kr.$ext"; then
      pkgfile="$work/kr.$ext"; break
    fi
  done
  [[ -n $pkgfile ]] || die "cannot download $pkgdir from $REPO_CONF_URL"
  mkdir -p "$work/x"
  bsdtar -xf "$pkgfile" -C "$work/x" usr/share/pacman/keyrings
  install -d /usr/share/pacman/keyrings
  cp -a "$work/x/usr/share/pacman/keyrings/omarchy"* /usr/share/pacman/keyrings/
  pacman-key --populate omarchy
  rm -rf "$work"
  ok "keyring extracted from $pkgdir and populated via pacman-key"
fi

pacman -Sy --noconfirm >/dev/null   # DatabaseOptional: OK before keyring exists
pacman -S --noconfirm --needed --overwrite '/usr/share/pacman/keyrings/*' omarchy-keyring >/dev/null
ok "package DBs synced; omarchy-keyring registered with pacman"

# --------------------------------------------------------- phase 2: packages
step "Phase 2 — Omarchy packages"
pkgout=$(mktemp)
if ! pacman -S --noconfirm --needed omarchy omarchy-settings >"$pkgout" 2>&1; then
  cat "$pkgout" >&2; rm -f "$pkgout"
  die "failed to install omarchy + omarchy-settings"
fi
rm -f "$pkgout"
ok "omarchy + omarchy-settings installed: $(pacman -Q omarchy | awk '{print $2}')"

PKGS_FILE="$OMARCHY_SHARE/install/omarchy-base.packages"
[[ -f $PKGS_FILE ]] || die "$PKGS_FILE missing — omarchy package incomplete?"
mapfile -t PKGS < <(grep -vE '^[[:space:]]*(#|$)' "$PKGS_FILE")

# Pre-filter packages whose "Conflicts With" is already installed (mise-bin
# conflicts with an installed mise): one conflict aborts the whole bulk
# transaction and would block every unrelated package too.
TO_INSTALL=(); PROVIDED=()
for p in "${PKGS[@]}"; do
  alt=""
  if ! pacman -Q "$p" >/dev/null 2>&1; then
    while read -r c; do
      c=${c%%[<>=]*}
      [[ -z $c || $c == None ]] && continue
      if LC_ALL=C pacman -Q "$c" >/dev/null 2>&1; then alt="$c"; break; fi
    done < <(LC_ALL=C pacman -Si "$p" 2>/dev/null | sed -n 's/^Conflicts With *: *//p' | tr ' ' '\n')
  fi
  if [[ -n $alt ]]; then PROVIDED+=("$p→$alt"); else TO_INSTALL+=("$p"); fi
done
((${#PROVIDED[@]})) && ok "skipping packages already provided otherwise: ${PROVIDED[*]}"

bulkout=$(mktemp)
if pacman -S --noconfirm --needed "${TO_INSTALL[@]}" >"$bulkout" 2>&1; then
  ok "default package set installed (${#TO_INSTALL[@]} of ${#PKGS[@]} entries, --needed)"
  rm -f "$bulkout"
else
  tail -6 "$bulkout" >&2 || true
  rm -f "$bulkout"
  warn "bulk install failed — retrying packages individually"
  failed=()
  for p in "${TO_INSTALL[@]}"; do
    pacman -S --noconfirm --needed "$p" >/dev/null 2>&1 || failed+=("$p")
  done
  ((${#failed[@]} == 0)) && ok "all packages installed on retry" \
    || warn "packages still missing: ${failed[*]}"
fi

if (( OMARCHY_MIRRORS )); then
  warn "switching [core]/[extra] to Omarchy mirrors — this runs pacman -Syyuu and DOWNGRADES anything newer than the stable pins"
  env OMARCHY_PATH="$OMARCHY_SHARE" omarchy-refresh-pacman "$CHANNEL"
  ok "omarchy-refresh-pacman $CHANNEL complete"
else
  ok "keeping your existing Arch mirrors (use --omarchy-mirrors to switch)"
fi

# --------------------------------------------- phase 3: user + system config
step "Phase 3 — user + omarchy-apply-system"
NEW_USER=0
if ! id "$TARGET_USER" >/dev/null 2>&1; then
  useradd -m -G wheel -s /bin/bash "$TARGET_USER"
  NEW_USER=1
  ok "created user $TARGET_USER (wheel) — set a password:"
  passwd "$TARGET_USER"
fi
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
[[ -d $TARGET_HOME ]] || die "home directory $TARGET_HOME missing"

# snapper: create-config insists on creating /.snapshots itself and fails
# whenever it already exists (mounted @snapshots, prior setup, or our own
# Phase 0), and set -e aborts apply-system there. Pre-seeding an empty config
# makes snapper.sh skip create-config; it installs Omarchy's template
# unconditionally afterwards (gotcha G2).
if [[ ! -f /etc/snapper/configs/root ]]; then
  install -d /etc/snapper/configs
  : >/etc/snapper/configs/root
  ok "pre-seeded empty /etc/snapper/configs/root (skips create-config failure)"
else
  SNAPPER_BAK="/etc/snapper/configs/root.bak.omarchy-$TS"
  cp -a /etc/snapper/configs/root "$SNAPPER_BAK"
  ok "existing snapper config backed up (Omarchy applies its 5-snapshot retention)"
fi

env -u OMARCHY_PATH omarchy-apply-system --install-user "$TARGET_USER" --first-install
ok "omarchy-apply-system complete (see $OMARCHY_SHARE phase log: /var/log/omarchy-install.log)"

# archinstall-style KEYMAP=(unset) breaks mkinitcpio's keymap hook
# (loadkeys: Unable to open file: unset) and leaves omarchy's hypr input.lua
# without an XKBLAYOUT to read — rewrite exactly like the ISO's keyboard.py:
# systemd-firstboot --keymap, preserving any FONT line.
if [[ -f /etc/vconsole.conf ]] && grep -qE '^KEYMAP=(\(unset\))?$' /etc/vconsole.conf; then
  km=$(localectl --no-pager status 2>/dev/null | sed -n 's/^ *VC Keymap: //p')
  [[ -z $km || $km == '(unset)' || $km == n/a ]] \
    && km=$(localectl --no-pager status 2>/dev/null | sed -n 's/^ *X11 Layout: //p')
  [[ -z $km || $km == '(unset)' || $km == n/a ]] && km=us
  km=${km%%,*}
  fontline=$(grep -m1 '^FONT=' /etc/vconsole.conf || true)
  if systemd-firstboot --keymap="$km" --force >/dev/null 2>&1; then
    [[ -n $fontline ]] && printf '%s\n' "$fontline" >>/etc/vconsole.conf
    ok "vconsole.conf rewritten (KEYMAP=$km + XKBLAYOUT) — fixes loadkeys 'unset' on UKI builds"
  else
    warn "could not rewrite vconsole.conf — run manually: systemd-firstboot --keymap=us --force"
  fi
fi

# snapperd may have started while the configs dir was empty and never re-scans
# (gotcha G3) — restart it now that the final config is in place.
systemctl restart snapperd.service 2>/dev/null || warn "could not restart snapperd"
if snapper -c root list >/dev/null 2>&1; then
  ok "snapper 'root' config active"
else
  warn "snapper 'root' config not readable — check /etc/snapper/configs/root"
fi

# ---------------------------------------------------------------- phase 4: $HOME
step "Phase 4 — user home: skel replay + provisioning"
if (( NEW_USER == 1 )); then
  ok "useradd -m already seeded $TARGET_HOME from /etc/skel"
elif (( NO_SKEL )); then
  ok "skel replay skipped (--no-skel-replay)"
else
  BACKUP="/root/omarchy-home-prelayer-$TS.tar.gz"
  HOME_BAK="$BACKUP"
  tar -czf "$BACKUP" -C "$TARGET_HOME" \
    --exclude='.config/chromium' --exclude='.config/google-chrome*' \
    --exclude='.config/BraveSoftware' --exclude='.config/microsoft-edge*' \
    .config .bashrc .bash_profile .profile 2>/dev/null \
    || warn "home backup incomplete (some files may not exist — fine)"
  cp -af /etc/skel/. "$TARGET_HOME/"
  chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME"
  ok "replayed /etc/skel over $TARGET_HOME (backup: $BACKUP)"
fi

RUNTIME_DIR="/run/user/$(id -u "$TARGET_USER")"
install -d -m 755 /run/user
[[ -d $RUNTIME_DIR ]] || install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$RUNTIME_DIR"

# sudo -u is a non-login shell: /etc/profile.d/omarchy.sh never runs, so pass
# OMARCHY_PATH explicitly (G1). provision-user must run AS the user (G8) and
# needs the network Node source because there is no ISO /opt/packages bundle (G9).
as_user() {
  sudo -u "$TARGET_USER" env \
    HOME="$TARGET_HOME" \
    OMARCHY_PATH="$OMARCHY_SHARE" \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    OMARCHY_SETUP_CONTEXT=provision-owner \
    PATH="$OMARCHY_SHARE/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$@"
}

if as_user omarchy-provision-user --first-install; then
  ok "omarchy-provision-user complete (mise/node, chromium hosts, keyring, git, theme)"
else
  warn "omarchy-provision-user failed — re-run manually:"
  warn "  sudo -u $TARGET_USER OMARCHY_PATH=$OMARCHY_SHARE OMARCHY_SETUP_CONTEXT=provision-owner omarchy-provision-user --first-install"
fi

# -------------------------------------------------- phase 5: SDDM login state
step "Phase 5 — SDDM login/autologin state (ISO configure_login equivalent)"
install -d -m 755 /etc/sddm.conf.d
printf '[Theme]\nCurrent=omarchy\n\n[Users]\nRememberLastUser=true\nRememberLastSession=true\n' \
  >/etc/sddm.conf.d/99-omarchy-login.conf
install -d -m 755 /var/lib/sddm
printf '[Last]\nSession=omarchy.desktop\nUser=%s\n' "$TARGET_USER" >/var/lib/sddm/state.conf
chown -R sddm:sddm /var/lib/sddm
# findmnt appends the btrfs subvol as "[/@]" — strip it or every device probe
# fails; lsblk ancestor walk also catches LVM-on-LUKS as encrypted.
ROOT_SRC=$(findmnt -no SOURCE / | sed 's/\[.*//')
if lsblk -sno TYPE "$ROOT_SRC" 2>/dev/null | grep -qx crypt; then
  printf '[Autologin]\nUser=%s\nSession=omarchy.desktop\n' "$TARGET_USER" \
    >/etc/sddm.conf.d/autologin.conf
  ok "encrypted root → autologin enabled (LUKS prompt is the auth boundary)"
else
  rm -f /etc/sddm.conf.d/autologin.conf
  ok "unencrypted root → normal SDDM password login"
fi
rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf
ok "greeter defaults + last-user state written"

# --------------------------------------------------- phase 6: user refreshes
step "Phase 6 — user-level refreshes (all as $TARGET_USER)"
for c in omarchy-refresh-applications omarchy-install-chromium-copy-url \
         omarchy-install-chromium-ytdlp omarchy-refresh-plymouth; do
  if as_user "$c" >/dev/null 2>&1; then
    ok "$c"
  else
    warn "$c failed — re-run as: sudo -u $TARGET_USER $c"
  fi
done
if command -v omarchy-nvim-refresh >/dev/null; then
  as_user omarchy-nvim-refresh >/dev/null 2>&1 && ok "omarchy-nvim-refresh" \
    || warn "omarchy-nvim-refresh failed"
elif command -v omarchy-nvim-setup >/dev/null; then
  as_user omarchy-nvim-setup --force >/dev/null 2>&1 && ok "omarchy-nvim-setup --force" \
    || warn "omarchy-nvim-setup failed"
fi

# ----------------------------------------------------- phase 7: boot integration
step "Phase 7 — boot integration (cmdline, UKI, Limine, snapshot menu)"
if [[ -x /usr/bin/limine-entry-tool || -x /usr/lib/limine/limine-entry-tool ]]; then
  # limine's package upgrade drops its own default limine.conf next to the ESP
  # binary; Limine's search order then ignores /boot/limine.conf (the file
  # omarchy regenerates below) — move conflicting copies aside, keeping backups.
  for eroot in /boot/EFI /boot/efi/EFI /efi/EFI; do
    [[ -d $eroot ]] || continue
    while IFS= read -r -d '' c; do
      mv "$c" "$c.omarchy-conflict-$TS"
      CONFLICT_MOVED=1
      ok "moved conflicting $c → $c.omarchy-conflict-$TS (omarchy owns /boot/limine.conf)"
    done < <(find "$eroot" -maxdepth 3 \( -name limine.conf -o -name limine.cfg \) -print0)
  done

  # /etc/kernel/cmdline — the base for the composed cmdline AND the UKI embed.
  # Missing it means Omarchy rebuilds the UKI with cosmetic params only:
  # no root=, no rd.luks.*, no rootflags → unbootable (gotcha G4).
  if [[ ! -f /etc/kernel/cmdline ]]; then
    sed -E 's#rootflags=subvol=/*#rootflags=subvol=/#' /proc/cmdline >/etc/kernel/cmdline
    chmod 644 /etc/kernel/cmdline
    ok "/etc/kernel/cmdline written from /proc/cmdline (rootflags normalized to subvol=/…)"
  else
    ok "/etc/kernel/cmdline already present — left untouched"
    grep -qE '(^|[[:space:]])(root=|rd\.luks)' /etc/kernel/cmdline \
      || warn "/etc/kernel/cmdline lacks root=/rd.luks — boot entries may be incomplete"
  fi

  # /etc/default/limine — KERNEL_CMDLINE wrapper read by limine-entry-tool.
  CL=$(tr -d '\n' </etc/kernel/cmdline)
  resolve_placeholder() {   # literal @@CMDLINE@@ substitution (&-safe)
    awk -v cl="$CL" '{ while ((i = index($0, "@@CMDLINE@@")) > 0)
      $0 = substr($0, 1, i - 1) cl substr($0, i + 11); print }' "$1"
  }
  if [[ ! -f /etc/default/limine ]]; then
    resolve_placeholder "$OMARCHY_SHARE/default/limine/default.conf" >/etc/default/limine
    chmod 644 /etc/default/limine
    ok "/etc/default/limine created from omarchy template"
  elif grep -q '@@CMDLINE@@' /etc/default/limine; then
    tmp=$(mktemp); resolve_placeholder /etc/default/limine >"$tmp"
    install -m 644 "$tmp" /etc/default/limine; rm -f "$tmp"
    ok "/etc/default/limine placeholder resolved"
  else
    ok "/etc/default/limine already configured — left untouched"
  fi

  limine-mkinitcpio && ok "UKI rebuilt with full cmdline" \
    || warn "limine-mkinitcpio failed — check kernel presets"
  if env OMARCHY_PATH="$OMARCHY_SHARE" omarchy-refresh-limine; then
    ok "limine.conf regenerated + limine-snapper-sync"
  else
    warn "omarchy-refresh-limine failed"
  fi

  if snapper -c root list >/dev/null 2>&1; then
    if snapper -c root list 2>/dev/null | grep -q 'omarchy layer baseline'; then
      BASELINE_OK=1
      ok "baseline snapshot already present"
    elif snapper -c root create -d "omarchy layer baseline" >/dev/null; then
      NEW_ID=$(snapper -c root list | tail -1 | sed -E 's/^[^0-9]*([0-9]+).*/\1/')
      [[ $NEW_ID =~ ^[0-9]+$ ]] || NEW_ID='?'
      BASELINE_OK=1
      ok "created bootable baseline snapshot: snapper #$NEW_ID"
    else
      warn "could not create baseline snapshot"
    fi
    limine-snapper-sync >/dev/null 2>&1 || warn "limine-snapper-sync failed"
    ok "snapshot boot menu synchronized"
  else
    warn "snapper unusable — no snapshot boot entries"
  fi
else
  warn "Limine tooling not found — skipping UKI/snapshot-menu integration;"
  warn "your existing bootloader keeps booting; Omarchy desktop still works"
fi

# ------------------------------------------------------------ phase 8: verify
step "Phase 8 — verification"
FAILS=0; WARNS=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAILS=$((FAILS + 1)); }
wrn()  { echo "  WARN  $*"; WARNS=$((WARNS + 1)); }

V=$(omarchy version 2>/dev/null || true)
if [[ $V =~ ^[0-9] ]]; then pass "omarchy $V"; else fail "omarchy CLI missing/broken"; fi

CH=$(env OMARCHY_PATH="$OMARCHY_SHARE" omarchy-channel-current 2>/dev/null || true)
if [[ $CH == "$CHANNEL" ]]; then pass "channel: $CH"
elif [[ -n $CH ]]; then wrn "channel reports '$CH' (expected '$CHANNEL')"
else wrn "omarchy-channel-current returned nothing"; fi

if pacman -Qkk omarchy 2>&1 | grep -q '0 altered files'; then
  pass "omarchy package files intact (pacman -Qkk)"
else
  fail "altered omarchy package files — pacman -S --overwrite='*' omarchy"
fi

for u in sddm NetworkManager snapperd; do
  systemctl is-active --quiet "$u" && pass "$u active" || fail "$u not active"
done
for u in sddm NetworkManager ufw cups docker.socket snapper-cleanup.timer limine-snapper-sync; do
  systemctl is-enabled --quiet "$u" 2>/dev/null && pass "$u enabled" || fail "$u not enabled"
done

snapper -c root list >/dev/null 2>&1 && pass "snapper 'root' functional" \
  || fail "snapper 'root' broken"

if [[ -f /etc/kernel/cmdline ]]; then
  grep -qE '(^|[[:space:]])(root=|rd\.luks)' /etc/kernel/cmdline \
    && pass "/etc/kernel/cmdline carries root params" \
    || fail "/etc/kernel/cmdline lacks root params"
else
  wrn "/etc/kernel/cmdline absent (no Limine integration?)"
fi

if command -v limine-entry-tool >/dev/null; then
  COMPOSED=$(limine-entry-tool --get-cmdline linux --no-mutex --no-hooks 2>/dev/null | tail -1)
  grep -qE '(^|[[:space:]])root=' <<<"$COMPOSED" \
    && pass "composed kernel cmdline carries root=" \
    || fail "composed cmdline lacks root=: $COMPOSED"
fi

if [[ -f /boot/limine.conf ]]; then
  grep -E '^ *cmdline:' /boot/limine.conf | grep -q 'root=' \
    && pass "limine.conf cmdline entries carry root=" \
    || fail "limine.conf cmdlines lack root= (re-run omarchy-refresh-limine)"
  grep -q 'Snapshots' /boot/limine.conf && pass "snapshot menu section present" \
    || wrn "no snapshot entries in limine.conf yet"
  ENTRY_HASH=$(grep -oE 'omarchy_linux\.efi#[0-9a-f]+' /boot/limine.conf | head -1 | cut -d'#' -f2)
  if [[ -n $ENTRY_HASH && -f /boot/EFI/Linux/omarchy_linux.efi ]]; then
    FILE_HASH=$(b2sum /boot/EFI/Linux/omarchy_linux.efi | cut -d' ' -f1)
    [[ $FILE_HASH == "$ENTRY_HASH" ]] \
      && pass "UKI hash matches limine.conf (blake2b-512)" \
      || fail "UKI hash mismatch — re-run: omarchy-refresh-limine"
  fi
fi

ROOT_SRC=$(findmnt -no SOURCE / | sed 's/\[.*//')
if lsblk -sno TYPE "$ROOT_SRC" 2>/dev/null | grep -qx crypt; then
  [[ -f /etc/sddm.conf.d/autologin.conf ]] \
    && pass "encrypted root: SDDM autologin configured" \
    || fail "encrypted root: autologin.conf missing"
else
  [[ ! -f /etc/sddm.conf.d/autologin.conf ]] \
    && pass "unencrypted root: password login (no autologin)" \
    || fail "unencrypted root: autologin.conf should not exist"
fi

[[ -f /usr/local/share/wayland-sessions/omarchy.desktop ]] \
  && pass "omarchy.desktop session registered" || fail "omarchy.desktop session missing"

ESPCONFLICTS=()
for eroot in /boot/EFI /boot/efi/EFI /efi/EFI; do
  [[ -d $eroot ]] || continue
  while IFS= read -r f; do ESPCONFLICTS+=("$f"); done \
    < <(find "$eroot" -maxdepth 3 \( -name limine.conf -o -name limine.cfg \) 2>/dev/null)
done
if ((${#ESPCONFLICTS[@]})); then
  fail "conflicting limine config(s) on the ESP: ${ESPCONFLICTS[*]} — boot may ignore /boot/limine.conf"
else
  pass "no conflicting limine configs on the ESP (single source: /boot/limine.conf)"
fi

if [[ -f /etc/vconsole.conf ]] && grep -qE '^KEYMAP=(\(unset\))?$' /etc/vconsole.conf; then
  fail "vconsole.conf still has KEYMAP=(unset) — UKI builds warn 'loadkeys: unset'"
else
  pass "vconsole.conf keymap configured"
fi

BAD=0; CHECKED=0
while IFS= read -r -d '' j; do
  CHECKED=$((CHECKED + 1))
  grep -q '/usr/share/omarchy' "$j" || BAD=$((BAD + 1))
done < <(find "$TARGET_HOME/.config" -path '*NativeMessagingHosts/com.omarchy.*.json' -print0 2>/dev/null)
if (( CHECKED == 0 )); then
  wrn "no native-messaging host JSONs yet (install a browser, then omarchy-install-chromium-copy-url)"
elif (( BAD == 0 )); then
  pass "$CHECKED native-messaging hosts point at /usr/share/omarchy"
else
  fail "$BAD native-messaging host JSON(s) reference a wrong path — re-run omarchy-install-chromium-copy-url and -ytdlp"
fi

id -nG "$TARGET_USER" | grep -qw wheel && pass "$TARGET_USER in wheel" \
  || fail "$TARGET_USER not in wheel"

echo
if (( FAILS > 0 )); then
  echo "Verification: $FAILS FAIL, $WARNS WARN — full log: $LOG"
  exit 1
fi
echo "Verification: all checks passed ($WARNS warning(s)) — full log: $LOG"
echo
echo "Layer complete. REBOOT to enter Omarchy:"
echo "  • encrypted root: LUKS passphrase, then autologin to the desktop"
echo "  • unencrypted:    SDDM password login"
echo "Rollback:"
(( BASELINE_OK )) && echo "  • bootable Omarchy baseline: Limine -> Snapshots menu ('omarchy layer baseline')"
[[ -n $ROLLBACK_SNAP ]] && echo "  • pre-layer snapshot: Limine -> Snapshots menu, or $ROLLBACK_SNAP (read-only)"
[[ -n $PACMAN_BAK ]]  && echo "  • $PACMAN_BAK"
[[ -n $SNAPPER_BAK ]] && echo "  • $SNAPPER_BAK"
[[ -n $HOME_BAK ]]    && echo "  • $HOME_BAK"
[[ -n $CONFLICT_MOVED ]] && echo "  • moved ESP limine config(s) preserved as *.omarchy-conflict-$TS"
exit 0
