#!/usr/bin/env bash
# fingerprint.sh — end-to-end install of the Goodix 27c6:55a4 fingerprint stack
# on this laptop (Arch Linux / Omarchy / Hyprland).
#
# Follows /home/mihai/Projects/fingerprint-goodix/DOCUMENTATION.md step by step:
#   0. hardware detection
#   1. package installation (runtime + build deps)
#   2. build patched libfprint (goodixtls55x4 driver) from the pinned commit + patch
#   3. one-time TLS key provisioning + install into /opt + fprintd drop-in
#   4. reliability guards (sleep fix, stop timeout, runtime max, udev, resume)
#   5. enrollment (right index finger) + verification
#   6. PAM wiring (sudo, polkit, lock screen) via omarchy-apply-lock
#
# Run as your normal user; privileged steps escalate through sudo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOODIX="$SCRIPT_DIR/goodix-27c6-55a4-fingerprint-linux"
FPDUMP="$SCRIPT_DIR/goodix-fp-dump"

FORK_URL="https://github.com/TheWeirdDev/libfprint.git"
FORK_REV="d1ca62a801aa565e67d1a2a47aaa7a33232b7990"
DUMP_URL="https://github.com/goodix-fp-linux-dev/goodix-fp-dump.git"
DUMP_REV="cc43bb3b3154a0bccc0412ae024013c7e1923139"

OMARCHY_BIN=/usr/share/omarchy/bin

step() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

SUDO=sudo

# --- 0. Hardware -----------------------------------------------------------------

step "0/8 checking for the Goodix fingerprint sensor"
if ! /usr/bin/omarchy-hw-fingerprint; then
  die "No fingerprint sensor detected. Install usbutils/fprintd first, then check: lsusb | grep -i goodix"
fi
if command -v lsusb >/dev/null 2>&1; then
  lsusb | grep -i goodix || true
fi

# --- 1. Packages ----------------------------------------------------------------

step "1/8 installing packages (runtime + build deps)"
$SUDO pacman -S --needed --noconfirm -- \
  fprintd usbutils libfprint-git \
  git curl base-devel meson ninja gcc pkg-config \
  glib2-devel libgusb nss openssl cairo pixman opencv doctest python python-virtualenv

# sigfm (in the patched libfprint) wants the pkg-config name "opencv4"; this
# system ships OpenCV 5, so alias opencv5.pc -> opencv4.pc when missing.
if [ ! -f /usr/lib/pkgconfig/opencv4.pc ]; then
  $SUDO cp /usr/lib/pkgconfig/opencv5.pc /usr/lib/pkgconfig/opencv4.pc
fi

# --- 2. Build patched libfprint --------------------------------------------------

step "2/8 building patched libfprint (goodixtls55x4)"
BUILD="$(mktemp -d -p /var/tmp goodix55a4.XXXXXXXX)"
cleanup() { rm -rf "$BUILD"; }
trap cleanup EXIT

git clone -q --branch 55b4-experimental "$FORK_URL" "$BUILD/libfprint"
git -C "$BUILD/libfprint" checkout -q "$FORK_REV"
git -C "$BUILD/libfprint" apply "$GOODIX/patches/55a4-driver.patch"
bash "$GOODIX/scripts/meson-build-libfprint.sh" "$BUILD/libfprint"
echo "   built: $BUILD/libfprint/build/libfprint"

# --- 3. Install + one-time TLS key provisioning ---------------------------------

step "3/8 installing patched libfprint into /opt and provisioning the TLS key"
$SUDO env \
  FP_SO_SRC="$BUILD/libfprint/build/libfprint" \
  FP_PYDIR="$BUILD/goodix-fp-dump" \
  bash "$GOODIX/scripts/install-system.sh"

# --- 4. Reliability guards -------------------------------------------------------

step "4/8 installing reliability guards"
$SUDO install -d /etc/systemd/system/fprintd.service.d
$SUDO tee /etc/systemd/system/fprintd.service.d/10-goodix55a4.conf > /dev/null <<'EOF'
[Service]
Environment=LD_LIBRARY_PATH=/opt/libfprint-goodix/lib64
EOF
$SUDO tee /etc/systemd/system/fprintd.service.d/10-stop-timeout.conf > /dev/null <<'EOF'
# A stale device handle can make fprintd ignore SIGTERM after resume.
# The numeric prefix lets an administrator's override.conf take precedence.
[Service]
TimeoutStopSec=3s
EOF
$SUDO tee /etc/systemd/system/fprintd.service.d/20-goodix-runtime-max.conf > /dev/null <<'EOF'
[Service]
RuntimeMaxSec=600
EOF
$SUDO tee /etc/udev/rules.d/61-goodix-no-autosuspend.rules > /dev/null <<'EOF'
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="27c6", ATTR{idProduct}=="55a4", ATTR{power/control}="on"
EOF
$SUDO tee /etc/systemd/system/fprintd-sleep-fix.service > /dev/null <<'EOF'
[Unit]
Description=Release Goodix fingerprint sensor around suspend (stale-claim fix)
Before=sleep.target
StopWhenUnneeded=yes

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/systemctl stop fprintd.service
ExecStop=/usr/bin/systemctl restart fprintd.service

[Install]
WantedBy=sleep.target
EOF
$SUDO install -Dm755 "$OMARCHY_BIN/../default/systemd/system-sleep/fprintd-resume" /usr/lib/systemd/system-sleep/fprintd-resume

$SUDO systemctl daemon-reload
$SUDO systemctl restart fprintd.service

# --- 5. Enrollment + verification -----------------------------------------------

step "5/8 enrolling (right index finger) and verifying"
if ! $SUDO sh -c 'authselect current 2>/dev/null | grep -q with-fingerprint'; then
  $SUDO authselect enable-feature with-fingerprint
fi
if ! $SUDO fprintd-enroll "$USER"; then
  die "Enrollment failed."
fi
if ! $SUDO fprintd-verify "$USER"; then
  die "Verification failed."
fi

# --- 6. PAM wiring --------------------------------------------------------------

step "6/8 wiring PAM (sudo, polkit, lock screen)"
$SUDO tee /etc/pam.d/sudo > /dev/null <<'EOF'
#%PAM-1.0
auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      sufficient pam_fprintd.so
auth		include		system-auth
account		include		system-auth
session		include		system-auth
session   	optional	pam_systemd.so class=none
EOF
$SUDO tee /etc/pam.d/polkit-1 > /dev/null <<'EOF'
auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      sufficient pam_fprintd.so
auth      include system-auth

account   include system-auth
password  include system-auth
session   include system-auth
EOF
# Writes /etc/pam.d/omarchy-lock-password and /etc/pam.d/omarchy-lock-fingerprint
# (the latter only once a fingerprint is enrolled and verified).
$SUDO env OMARCHY_PATH=/usr/share/omarchy "$OMARCHY_BIN/omarchy-apply-lock"

# --- 7. Final state -------------------------------------------------------------

step "7/8 restarting fprintd and listing enrolled fingers"
$SUDO systemctl restart fprintd.service
if ! $SUDO fprintd-list "$USER"; then
  die "Could not list enrolled fingerprints."
fi

printf '\n\033[1;32mFingerprint setup completed.\033[0m\n'
printf 'Verified working: sudo fingerprint, polkit, and lock screen (Super + Ctrl + L).\n'
printf 'Rollback: sudo bash %s/scripts/uninstall-system.sh\n' "$GOODIX"
