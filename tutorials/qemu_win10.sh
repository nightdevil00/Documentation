#!/usr/bin/env bash
#
# qemu-win11.sh - boot a Windows installer ISO in QEMU against a raw NVMe
# block device, entirely from the host side.
#
# The host-side approach documented in ~/nvme_install_omarchy.md: QEMU uses the
# block device as a raw (format=raw) backend and emulates an NVMe controller on
# top, so no VFIO/IOMMU is needed. Defaults to the verified Windows 10 22H2 ISO.
#
#   ./qemu-win11.sh                       # install to /dev/nvme0n1
#   ISO=~/Downloads/other.iso ./qemu-win11.sh
#   DISK=/dev/nvme0n1 ./qemu-win11.sh     # explicit target
#   DISPLAY_MODE=sdl ./qemu-win11.sh      # alternate display
#   NET=user ./qemu-win11.sh              # opt into a user-mode NIC (has internet)
#   ./qemu-win11.sh --yes -snapshot       # no-write dry run
#
# Networking is OFF by default (no NIC): without this the guest would get QEMU's
# implicit user-mode NIC and reach the internet during Setup/OOBE.
#
set -euo pipefail

# ---- configuration (override via environment) -------------------------------
DISK="${DISK:-/dev/nvme0n1}"
ISO="${ISO:-/home/mihai/Win10_22H2_English_x64v1.iso}"
RAM="${RAM:-16384}"
CPUS="${CPUS:-8}"
VMSTATE="${VMSTATE:-/home/mihai/.local/share/qemu-win11}"
DISPLAY_MODE="${DISPLAY_MODE:-gtk}"
NET="${NET:-none}"               # QEMU -nic value; none -> no NIC, so the guest
                                 # has NO internet (no downloads during Setup/OOBE).
                                 # Use NET=user for the default user-mode NAT.
SECBOOT="${SECBOOT:-0}"          # 1 -> OVMF_CODE.secboot.4m.fd
REUSE_TPM="${REUSE_TPM:-0}"      # 1 -> keep swtpm state across runs
TPM="${TPM:-auto}"               # auto -> attach TPM only if swtpm is present

OVMF_DIR=/usr/share/edk2/x64
if [ "$SECBOOT" = 1 ]; then
  OVMF_CODE="$OVMF_DIR/OVMF_CODE.secboot.4m.fd"
else
  OVMF_CODE="$OVMF_DIR/OVMF_CODE.4m.fd"
fi
OVMF_VARS_TPL="$OVMF_DIR/OVMF_VARS.4m.fd"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- argument parsing (only our own flags; the rest goes to QEMU) -----------
ASSUME_YES=0
QEMU_EXTRA=()
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    *)        QEMU_EXTRA+=("$arg") ;;
  esac
done

# ---- privileges -------------------------------------------------------------
# QEMU needs raw block-device access, so it runs elevated. Everything else
# (state dir, swtpm) stays with the invoking user, which is why paths are
# absolute rather than $HOME-based ($HOME becomes /root under sudo).
if [ "$(id -u)" -eq 0 ]; then
  SUDO=()
  RUN_HOME="${SUDO_USER:+/home/$SUDO_USER}"; RUN_HOME="${RUN_HOME:-/root}"
else
  SUDO=(sudo -E)
  RUN_HOME="$HOME"
fi
sudo -n true 2>/dev/null || die "passwordless sudo is required (sudo -n true failed)."

# ---- preflight --------------------------------------------------------------
[ -b "$DISK" ] || die "$DISK is not a block device."
[ -f "$ISO" ]  || die "ISO not found: $ISO (set ISO=/path/to.iso)"
[ -f "$OVMF_CODE" ]     || die "missing firmware: $OVMF_CODE (pacman -S edk2-ovmf)"
[ -f "$OVMF_VARS_TPL" ] || die "missing NVRAM template: $OVMF_VARS_TPL"

BLK="$(basename "$DISK")"
if compgen -G "/sys/block/$BLK/holders/*" >/dev/null; then
  die "$DISK is in use (holders present) - refusing."
fi
if lsblk -rno MOUNTPOINT "$DISK" 2>/dev/null | grep -qv '^$'; then
  die "$DISK has a mounted partition - refusing. Unmount it first."
fi

# Refuse to aim at the disk carrying the running root filesystem.
ROOT_SRC="$(findmnt -rno SOURCE / || true)"
if [ -n "$ROOT_SRC" ] && [ "${ROOT_SRC%%\[*}" = "$DISK"* ]; then
  die "$DISK carries the host root filesystem ($ROOT_SRC) - refusing."
fi

# ---- firmware NVRAM ---------------------------------------------------------
mkdir -p "$VMSTATE/tpm"
if [ ! -f "$VMSTATE/OVMF_VARS.fd" ]; then
  cp "$OVMF_VARS_TPL" "$VMSTATE/OVMF_VARS.fd"
  chmod u+w "$VMSTATE/OVMF_VARS.fd"
  say "seeded $VMSTATE/OVMF_VARS.fd from template"
fi

# ---- confirmation -----------------------------------------------------------
say "target disk : $DISK  ($(lsblk -rno SIZE,MODEL "$DISK" | head -1))"
say "iso         : $ISO"
say "firmware    : $OVMF_CODE   (secboot=$SECBOOT)"
if [ "$ASSUME_YES" != 1 ]; then
  printf '\033[1;33mThis ERASES %s. Type "erase" to continue: \033[0m' "$DISK"
  read -r reply
  [ "$reply" = erase ] || die "aborted."
fi

# ---- optional TPM 2.0 (needed by the Windows 11 gate, not by Win10) ---------
TPM_ARGS=()
SWTPM_PID=""
if [ "$TPM" != 0 ] && command -v swtpm >/dev/null 2>&1; then
  if [ "$REUSE_TPM" != 1 ]; then rm -rf "$VMSTATE/tpm"; mkdir -p "$VMSTATE/tpm"; fi
  swtpm socket --tpm2 --tpmstate dir="$VMSTATE/tpm" \
    --ctrl type=unixio,path="$VMSTATE/tpm/sock" --daemon --pid file="$VMSTATE/tpm/pid"
  SWTPM_PID="$(cat "$VMSTATE/tpm/pid" 2>/dev/null || true)"
  trap '[ -n "$SWTPM_PID" ] && kill "$SWTPM_PID" 2>/dev/null || true' EXIT
  TPM_ARGS=(-chardev socket,id=chrtpm,path="$VMSTATE/tpm/sock"
            -tpmdev emulator,id=tpm0,chardev=chrtpm
            -device tpm-crb,tpmdev=tpm0)
  say "TPM 2.0 emulator attached (swtpm)"
else
  warn "swtpm not found or TPM=0 - running without TPM (fine for Windows 10)"
fi

# ---- display ---------------------------------------------------------------
case "$DISPLAY_MODE" in
  gtk)     DISPLAY_ARGS=(-display gtk) ;;
  sdl)     DISPLAY_ARGS=(-display sdl) ;;
  curses)  DISPLAY_ARGS=(-display curses) ;;
  none)    DISPLAY_ARGS=(-display none) ;;
  nographic) DISPLAY_ARGS=(-nographic) ;;
  *)       DISPLAY_ARGS=(-display "$DISPLAY_MODE") ;;
esac

# ---- run --------------------------------------------------------------------
say "starting QEMU (Ctrl-Alt-G releases the pointer; close the window to quit)"
set -x
"${SUDO[@]}" qemu-system-x86_64 \
  -machine q35 \
  -enable-kvm -cpu host -m "$RAM" -smp "$CPUS" \
  -nic "$NET" \
  -drive if=none,id=nvmedisk,file="$DISK",format=raw,cache=none \
  -device nvme,drive=nvmedisk,serial=host-nvme0,bootindex=1 \
  "${TPM_ARGS[@]}" \
  -device qemu-xhci,id=xhci \
  -device usb-tablet,bus=xhci.0 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$VMSTATE/OVMF_VARS.fd" \
  -drive if=none,id=cd,file="$ISO",media=cdrom,readonly=on \
  -device ide-cd,drive=cd,bootindex=2 \
  -boot order=cd,menu=off \
  -rtc base=localtime \
  -monitor unix:"$VMSTATE/monitor.sock",server,nowait \
  "${DISPLAY_ARGS[@]}" \
  "${QEMU_EXTRA[@]}"
