#!/usr/bin/env bash
# qemu-win11.sh — install Windows to /dev/nvme0n1 from the host side
#
# Defaults to the verified Windows 10 22H2 ISO, which needs no Secure Boot
# bypass. To retry Windows 11 instead, point ISO at a patched image (see
# nvme_install_omarchy.md) or override it on the command line:
#   ISO=~/Downloads/Win11_patched.iso ./qemu-win11.sh
set -euo pipefail

ISO="${ISO:-$HOME/Downloads/Win10_22H2_English_x64v1.iso}"
DISK="${DISK:-/dev/nvme1n1}"
VMSTATE="${VMSTATE:-$HOME/.local/share/qemu-win11}"
RAM="${RAM:-16384}"
CPUS="${CPUS:-8}"

OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.4m.fd
OVMF_CODE_SB=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd
OVMF_VARS_TPL=/usr/share/edk2/x64/OVMF_VARS.4m.fd

say()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# --- preflight -------------------------------------------------------------
[ -f "$ISO" ] || die "ISO not found: $ISO"
[ -f "$OVMF_CODE" ] || die "OVMF firmware missing: $OVMF_CODE"
[ -b "$DISK" ] || die "not a block device: $DISK"
[ -w /dev/kvm ] || die "/dev/kvm not accessible (no KVM?)"
command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not found"

resolved=$(readlink -f "$DISK")
[ "$resolved" = "/dev/nvme1n1" ] || die "refusing to touch $resolved (set DISK= to override deliberately)"

say "ISO   $ISO ($(du -h "$ISO" | cut -f1))"
say "disk  $resolved"
if command -v lsblk >/dev/null; then
  warn "current layout on $resolved:"
  lsblk -no NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$resolved" | sed 's/^/      /' || true
fi
warn "installer will ERASE $resolved"

ASSUME_YES=0
QEMU_EXTRA=()
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    *) QEMU_EXTRA+=("$arg") ;;
  esac
done

if [ "$ASSUME_YES" -ne 1 ]; then
  read -rp "Type 'erase' to continue: " reply
  [ "$reply" = "erase" ] || die "aborted"
fi

# --- swtpm (TPM 2.0 emulator; Windows 11 requires it, Windows 10 does not) --
if ! command -v swtpm >/dev/null; then
  say "installing swtpm (TPM 2.0 emulator)"
  sudo pacman -S --needed --noconfirm swtpm
fi
command -v swtpm >/dev/null || die "swtpm still missing after install"

# --- persistent state ------------------------------------------------------
mkdir -p "$VMSTATE/tpm"
if [ ! -s "$VMSTATE/OVMF_VARS.fd" ]; then
  cp "$OVMF_VARS_TPL" "$VMSTATE/OVMF_VARS.fd"
fi

# Fresh TPM state each run unless REUSE_TPM=1
if [ "${REUSE_TPM:-0}" != "1" ]; then
  rm -f "$VMSTATE"/tpm/*.tpm "$VMSTATE"/tpm/*.lock
fi

say "starting swtpm"
swtpm socket --tpm2 --tpmstate dir="$VMSTATE/tpm" \
  --ctrl type=unixio,path="$VMSTATE/tpm/sock" \
  --daemon --pid file="$VMSTATE/tpm/swtpm.pid"

cleanup() {
  [ -f "$VMSTATE/tpm/swtpm.pid" ] && kill "$(cat "$VMSTATE/tpm/swtpm.pid")" 2>/dev/null || true
}
trap cleanup EXIT

# --- run -------------------------------------------------------------------
# SECBOOT=1 uses OVMF_CODE.secboot.4m.fd. Note: it has no MS keys enrolled by
# default, so Win11 may still need the Secure Boot check bypass (see notes).
if [ "${SECBOOT:-0}" = "1" ]; then
  OVMF_CODE="$OVMF_CODE_SB"
fi

case "${DISPLAY_MODE:-gtk}" in
  gtk)   DISPLAY_ARGS=(-display gtk) ;;
  none)  DISPLAY_ARGS=(-display none) ;;
  sdl)   DISPLAY_ARGS=(-display sdl) ;;
  curses) DISPLAY_ARGS=(-display curses) ;;
  nographic) DISPLAY_ARGS=(-nographic) ;;
  *) die "unknown DISPLAY_MODE: ${DISPLAY_MODE} (gtk|sdl|curses|nographic|none)" ;;
esac

say "booting installer — $RAM MB, $CPUS vCPU, UEFI, display=${DISPLAY_MODE:-gtk}"
say "Ctrl+Alt+G releases the mouse; quit with 'quit' at any qemu> prompt"
warn "if the window does not appear, try: DISPLAY_MODE=sdl $0"
cat <<'EOF'

    Setup notes:
      - Pick the disk by SIZE (477 GB), not by partition name.
      - Windows 10 OOBE may refuse local accounts. Shift+F10, then:
            OOBE\BYPASSNRO
      - Windows 11 may show "This PC can't run Windows 11" / "The PC must
        support Secure Boot." That gate is evaluated in WinPE (boot.wim).
        A stock OVMF_VARS.4m.fd publishes no Secure Boot variables at all,
        so a patched ISO is required. See nvme_install_omarchy.md.

EOF

# -E keeps DISPLAY/WAYLAND_DISPLAY/XAUTHORITY/XDG_RUNTIME_DIR through sudo;
# without it sudo's env_reset strips them and GTK fails to initialise.
sudo -E qemu-system-x86_64 \
  -machine q35 \
  -enable-kvm -cpu host -m "$RAM" -smp "$CPUS" \
  -drive if=none,id=nvmedisk,file="$resolved",format=raw,cache=none \
  -device nvme,drive=nvmedisk,serial=host-nvme0,bootindex=1 \
  -chardev socket,id=chrtpm,path="$VMSTATE/tpm/sock" \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-crb,tpmdev=tpm0 \
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
  "${QEMU_EXTRA[@]+"${QEMU_EXTRA[@]}"}"
