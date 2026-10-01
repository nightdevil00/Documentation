# Installing Windows to /dev/nvme0n1 via QEMU

Notes from installing an OS onto the secondary NVMe drive of an Omarchy laptop
using QEMU, entirely from the host side. Records the working configuration, the
ISO Secure Boot patch, and the failures that cost time along the way.

## Outcome

Windows 10 22H2 installed to `/dev/nvme0n1` using a stock, verified Microsoft
ISO. No patching required. Windows 11 was attempted first and abandoned because
of the Secure Boot gate (see [Windows 11 Secure Boot gate](#windows-11-secure-boot-gate)).

## Host environment

| | |
|---|---|
| OS | Arch / Omarchy, btrfs root |
| CPU | Intel Core i7-10750H (Comet Lake, 6c/12t) |
| RAM | 15 GiB total |
| QEMU | 11.1.1 |
| Firmware | edk2-ovmf 202608-1 at `/usr/share/edk2/x64/` |
| Session | Wayland / Hyprland, `DISPLAY=:0` |

Disks:

| Device | Size | Model | Role |
|---|---|---|---|
| `/dev/nvme0n1` | 477 GB | SK hynix HFM512GDHTNI-87A0B | **install target** |
| `/dev/nvme1n1` | 931 GB | Kingston SNV2S1000G | host root + `/home` |

Before starting, `/dev/nvme0n1` held an unmounted NixOS installation
(`p1` vfat ESP, `p2` btrfs `root`, `p3` swap) and had no holders in
`/sys/block/nvme0n1/holders/`, so it was safe to repurpose.

### No IOMMU

```
$ ls /sys/kernel/iommu_groups/     # empty
$ dmesg | grep -i -E 'AMD-Vi|Intel-IOMMU'   # nothing
```

PCI passthrough (VFIO) is **not available** on this machine. Not needed for this
approach — QEMU uses the block device as a raw backend and emulates an NVMe
controller on top. See [Why not VFIO passthrough](#why-not-vfio-passthrough).

## Quick start

```bash
/home/mihai/qemu-win11.sh
```

The script defaults to the verified Windows 10 ISO. Override with environment
variables:

```bash
ISO=~/Downloads/Win10_22H2_English_x64v1.iso ./qemu-win11.sh   # different path
DISK=/dev/nvme0n1 ./qemu-win11.sh                              # explicit disk
DISPLAY_MODE=sdl ./qemu-win11.sh                               # alternate display
./qemu-win11.sh --yes -snapshot                                # no-write dry run
```

| Variable | Default | Notes |
|---|---|---|
| `ISO` | `~/Downloads/Win10_22H2_English_x64v1.iso` | must be a UEFI-bootable ISO |
| `DISK` | `/dev/nvme0n1` | script refuses any other path unless overridden |
| `RAM` | `16384` | |
| `CPUS` | `8` | |
| `VMSTATE` | `~/.local/share/qemu-win11` | OVMF vars + TPM state |
| `DISPLAY_MODE` | `gtk` | `gtk`, `sdl`, `curses`, `nographic`, `none` |
| `SECBOOT` | `0` | `1` switches to `OVMF_CODE.secboot.4m.fd` |
| `REUSE_TPM` | `0` | `1` keeps TPM state across runs |

`--yes`/`-y` skips the `erase` confirmation. Unrecognised arguments are passed
through to QEMU, so `-snapshot` works.

## Verified ISO

Windows 10 22H2, used as-is with no modification:

```
Win10_22H2_English_x64v1.iso
  size    6140975104 bytes
  sha256  a6f470ca6d331eb353b815c043e327a347f594f37ff525f17764738fe812852e
  sha1    bbb1b234ea7f5397a1906ee59187087c78374f35
  md5     c2b19762870226ca467d6cbd87cd8fab
  volume  CCCOMA_X64FRE_EN-US_DV9
```

Microsoft's own hash list was unreachable from this environment. Size, SHA1, and
MD5 were cross-checked against an independent Internet Archive copy of the same
filename and all three agree. The `CCCOMA_*_DV9` volume ID is the standard
multi-edition consumer pattern. This is an unmodified Microsoft ISO.

Check any download before use:

```bash
file ~/Downloads/*.iso
sha256sum ~/Downloads/*.iso
xorriso -indev ~/Downloads/*.iso -report_el_torito plain 2>/dev/null \
  | sed -n '/El Torito images/,/img blks/p'
```

A UEFI entry in the El Torito table is what matters — that is what OVMF boots.

> The Windows 11 ISO (`Win11_25H2_English_x64_v2.iso`) is **7.9 GB**, larger than
> Microsoft's typical consumer image, and its hash could not be verified against
> any authoritative list. Treat it as untrusted. It was obtained from a
> third-party source.

## QEMU configuration

From `qemu-win11.sh`:

```bash
sudo -E qemu-system-x86_64 \
  -machine q35 \
  -enable-kvm -cpu host -m 16384 -smp 8 \
  -drive if=none,id=nvmedisk,file=/dev/nvme0n1,format=raw,cache=none \
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
  -display gtk
```

Why each non-obvious option:

| Option | Reason |
|---|---|
| `format=raw` | **mandatory** with a block device — QEMU cannot probe `/dev/*` |
| `cache=none` | O_DIRECT; guest writes reach the SSD immediately, so a hard kill mid-install loses nothing |
| `-device nvme` | guest sees a native NVMe controller, not SATA |
| `bootindex=1` on nvme, `2` on cd | disk first for the installed OS, CD second |
| `-boot order=cd` | **CD first**, so the installer actually starts |
| `usb-tablet` + `qemu-xhci` | absolute-positioning pointer; the Windows installer is unusable without it |
| `tpm-crb` + `swtpm` | TPM 2.0 for the Windows 11 gate (not needed for Win10) |
| `pflash` OVMF | UEFI boot; `bootmgfw.efi` on the ESP is what boots on real hardware later |
| `-E` on sudo | preserves `DISPLAY`/`WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR` through sudo's `env_reset` |
| `menu=off` | prevents a stale boot menu from reappearing |

### TPM 2.0 emulator

`swtpm` is required by the Windows 11 gate. Installed from `extra` on first run:

```bash
sudo pacman -S --needed swtpm
```

State lives in `~/.local/share/qemu-win11/tpm/`, reset each run unless
`REUSE_TPM=1`.

## Inside Setup

- Select the disk **by size (`477 GB`)**, which is `nvme0n1` — not
  `nvme0n1p1`/`p2`/`p3`. Those are the old NixOS partitions.
- Let Setup create its own partition layout (ESP / system / recovery).
- The host's boot drive is `/dev/nvme1n1p4`. Installing to it is the classic
  disaster here.

Win10 OOBE may refuse local accounts. `Shift+F10`, then:

```cmd
OOBE\BYPASSNRO
```

Setup restarts afterwards.

WinPE's `Shift+F10` console has **no shared clipboard** with the host. Anything
typed there must be entered by hand, and a single typo in a long registry path
fails silently. This is a strong argument for fixing problems on the host side
instead.

## After installation

Shut the guest down from Windows rather than killing QEMU, then clear host-side
partition metadata so nothing misreads the new layout:

```bash
sudo wipefs -a /dev/nvme0n1
sudo sgdisk --zap-all /dev/nvme0n1 2>/dev/null || true
sudo blkid /dev/nvme0n1*
```

Because the install ran under UEFI, the distro writes both
`\EFI\Microsoft\Boot\bootmgfw.efi` and the removable-media fallback
`\EFI\BOOT\BOOTX64.EFI`. The fallback is what boots on the laptop. The QEMU
NVRAM (`OVMF_VARS.fd`) is irrelevant on bare metal.

## Windows 11 Secure Boot gate

Windows 11 Setup refuses to install unless it sees UEFI **with Secure Boot**,
TPM 2.0, 4 GB+ RAM, and a supported CPU. On this host the TPM is fine
(`swtpm` + `tpm-crb` attach cleanly), but a stock `OVMF_VARS.4m.fd` publishes
**no Secure Boot variables at all** — confirmed from inside WinPE:

```
X:\sources>reg query "HKLM\SYSTEM\Control\SecureBoot\State" /v UEFISecureBootEnabled
ERROR: The system was unable to find the specified registry key or value.

X:\sources>reg query "HKLM\SYSTEM\CurrentControlSet\Services\TPM"
...  Tag  REG_DWORD  0x5      (TPM 2.0 — this one is fine)
```

The variable is *absent*, not `0x0`. That is the sole failing gate.

### Runtime bypass (unreliable here)

Setting the key in WinPE usually does not stick, because Setup caches its
hardware verdict. The full incantation:

```cmd
reg add "HKLM\SYSTEM\Setup\MoSetup" /v LabConfig /t REG_DWORD /f /d 7
reg add "HKLM\SYSTEM\Setup\MoSetup" /v BypassSecureBootCheck /t REG_DWORD /f /d 1
reg add "HKLM\SYSTEM\Setup\Status\ChildCompletion" /v setup.exe /t REG_DWORD /f /d 1
reg add "HKLM\SYSTEM\Setup\Status\ChildCompletion" /v setup /t REG_DWORD /f /d 1
wpeinit
C:\Windows\System32\setup.exe
```

`LabConfig 7` ORs the TPM (1), CPU (2), and RAM (4) bits. Secure Boot is covered
separately by `BypassSecureBootCheck`. `wpeinit` plus the explicit relaunch
forces Setup to re-evaluate. The `ChildCompletion` values are the part that
makes the relaunch actually happen.

This was not reliable in practice — no clipboard, so typos were likely, and each
attempt cost a full VM boot.

### Offline ISO patch

The robust approach. Write the bypass into the WIM registry hives so Setup never
sees the check.

**The critical detail: patch `boot.wim`, not just `install.wim`.** The gate is
evaluated in WinPE, which boots from `boot.wim`. `install.wim`'s registry is not
read until after the check has already passed. Patching only `install.wim` had
**zero effect** — which is exactly what happened here, wasting two build cycles.

Both WIMs, all images:

| WIM | Images | Content |
|---|---|---|
| `boot.wim` | 2 | WinPE — **this is where the gate is evaluated** |
| `install.wim` | 11 | Home / Pro / Education / Pro for Workstations, etc. |

Values written to `HKLM\Setup\MoSetup` in each image's
`\Windows\System32\config\SYSTEM`:

```
LabConfig             REG_DWORD  0x07
BypassSecureBootCheck REG_DWORD  0x01
```

Note `MoSetup` does not exist in the stock hives — it must be created.

#### Patch script

```bash
#!/bin/bash
# Patch LabConfig/BypassSecureBootCheck into the offline SYSTEM hive of boot.wim
# (where Setup evaluates the TPM/CPU/RAM/Secure-Boot gate) and install.wim.
set -euo pipefail

W=/home/mihai/win11patch
ISO_IN=/home/mihai/Downloads/Win11_22H2_patched.iso
ISO_OUT=/home/mihai/Downloads/Win11_22H2_patched.iso.new
LOG="$W/patch.log"
say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

: >"$LOG"
mkdir -p "$W"

# 1. copy the ISO tree out (loop-mount; see notes on 7z/xorriso below)
MNT="$W/iso"
rm -rf "$MNT" "$W/mk"; mkdir -p "$MNT"
sudo -n mount -o loop,ro "$ISO_IN" "$MNT"
sudo -n cp -a "$MNT"/. "$W/mk"/
sudo -n umount "$MNT"; rm -rf "$MNT"
say "copied ISO tree"

# 2. writable copies of both WIMs
for w in boot install; do
  sudo -n cp "$W/mk/sources/$w.wim" "$W/$w.wim"
  sudo -n chmod u+w "$W/$w.wim"
  nimg=$(wimlib-imagex info "$W/$w.wim" 2>/dev/null | awk '/Image Count:/ {print $3}')
  say "$w.wim has $nimg image(s)"

  # 3. patch every image in the WIM
  for i in $(seq 1 "$nimg"); do
    rm -rf "$W/fin"
    wimlib-imagex extract "$W/$w.wim" "$i" --dest-dir="$W/fin" --no-acls \
      '/Windows/System32/config/SYSTEM' >>"$LOG" 2>&1

    # Probe into a variable: piping into grep would trip `pipefail`,
    # since hivexsh exits non-zero on a failed cd.
    probe=$( { echo 'cd MoSetup'; echo 'q'; } | hivexsh "$W/fin/SYSTEM" 2>&1 || true )
    if [[ "$probe" == *"not found"* ]]; then
      mosetup_add="add MoSetup"
    else
      mosetup_add=""
    fi

    {
      echo 'cd Setup'
      if [ -n "$mosetup_add" ]; then echo "$mosetup_add"; fi
      echo 'cd MoSetup'
      echo 'setval 2'
      echo 'LabConfig'
      echo 'dword:0x00000007'
      echo 'BypassSecureBootCheck'
      echo 'dword:0x00000001'
      echo 'commit'
      echo 'q'
    } | hivexsh -w "$W/fin/SYSTEM" >>"$LOG" 2>&1

    printf '    %s image %-2s -> ' "$w.wim" "$i"
    echo 'cd Setup
cd MoSetup
lsval
q' | hivexsh "$W/fin/SYSTEM" 2>&1 | tr '\n' ' '
    echo

    echo "add $W/fin/SYSTEM /Windows/System32/config/SYSTEM" >"$W/cmd.txt"
    wimlib-imagex update "$W/$w.wim" "$i" <"$W/cmd.txt" >>"$LOG" 2>&1
  done
  rm -rf "$W/fin" "$W/cmd.txt"

  # 4. swap back and dedup
  sudo -n cp "$W/$w.wim" "$W/mk/sources/$w.wim"
  sudo -n chmod u+w "$W/mk/sources/$w.wim"
  sudo -n wimlib-imagex optimize "$W/mk/sources/$w.wim" >>"$LOG" 2>&1
  rm -f "$W/$w.wim"
done

# 5. rebuild the ISO, UEFI El Torito only
rm -f "$ISO_OUT"
sudo -n xorriso -as mkisofs \
  -iso-level 4 -full-iso9660-filenames -volid "WIN11_PATCHED" \
  -eltorito-alt-boot -e efi/microsoft/boot/efisys.bin -no-emul-boot \
  -output "$ISO_OUT" "$W/mk" >>"$LOG" 2>&1
say "rebuilt ISO"

# 6. verify by reading hives back out of the finished ISO
CHKMNT="$W/chk"; rm -rf "$CHKMNT"; mkdir -p "$CHKMNT"
sudo -n mount -o loop,ro "$ISO_OUT" "$CHKMNT"
for w in boot install; do
  n=$(wimlib-imagex info "$CHKMNT/sources/$w.wim" 2>/dev/null | awk '/Image Count:/ {print $3}')
  for i in $(seq 1 "$n"); do
    rm -rf "$W/fin"
    wimlib-imagex extract "$CHKMNT/sources/$w.wim" "$i" --dest-dir="$W/fin" \
      --no-acls '/Windows/System32/config/SYSTEM' >/dev/null 2>&1
    printf '%-12s image %-2s -> ' "$w.wim" "$i"
    echo 'cd Setup
cd MoSetup
lsval
q' | hivexsh "$W/fin/SYSTEM" 2>&1 | tr '\n' ' '
    echo
  done
done
sudo -n umount "$CHKMNT"

# 7. clean up, then swap the new ISO in
rm -rf "$CHKMNT" "$W/fin" "$W/mk"
sudo -n rm -rf "$W"
mv "$ISO_OUT" "$ISO_IN"
say "done - replaced $ISO_IN"
```

Dependencies, all in `extra`:

```bash
sudo pacman -S --needed wimlib hivex libisoburn
```

| Tool | Role |
|---|---|
| `wimlib-imagex` | extract / update / optimize WIM images |
| `hivexsh` | offline registry hive editing |
| `xorriso` (libisoburn) | ISO rebuild with El Torito |
| `swtpm` | TPM 2.0 at runtime |
| `edk2-ovmf` | OVMF UEFI firmware |

#### `hivexsh` syntax notes

Paths are **not** `/`-prefixed from the root, and matching is case-sensitive
against the WIM's stored casing (`/Windows/System32/config/SYSTEM`, not
`WINDOWS/...`).

```
cd Setup             # HKLM\Setup lives at the hive root, NOT under ControlSet001
add MoSetup          # create the key; fails if it already exists
setval 2             # replace both (name, value) pairs — reads 4 more lines
LabConfig
dword:0x00000007
BypassSecureBootCheck
dword:0x00000001
commit               # without -w, all writes are discarded
```

`hivexsh` needs `-w` to enable writes. Verify with `lsval` after committing.

#### ISO rebuild caveats

- `-iso-level` maxes at **4**; `-as mkisofs` rejects 5.
- The El Torito EFI image path is **`efi/microsoft/boot/efisys.bin`** (lowercase,
  as stored). `EFI/BOOT/BOOTX64.EFI` is found on disk but xorriso will not
  resolve it as a boot image.
- `-as mkisofs` does not accept `--interval:appended_partition_2:...`.
- The rebuild is **UEFI-only**. The original Microsoft ISO is hybrid BIOS+UEFI.
  Irrelevant for this QEMU setup (OVMF), but a patched image written to a USB
  stick will not offer legacy BIOS boot.

## Failures worth remembering

Each of these cost a build cycle.

**`7z` silently truncated `install.wim`** — 5.5 GB extracted from a 7.1 GB file,
with no error surfaced by the surrounding command. The Windows ISO is **UDF**,
and xorriso's tree load only sees the ISO9660 layer, so `-osirrox -extract`
returns almost nothing. Loop-mount the UDF filesystem instead:

```bash
sudo mount -o loop,ro image.iso /mnt/point
```

**`/tmp/opencode` is tmpfs capped at 7.7 GB** — copying a 7.1 GB WIM there fails
with `Disk quota exceeded`. Use a real-disk path for anything large.

**WIM inherited read-only permissions from the ISO** (`-r-xr-xr-x`), so
`wimlib-imagex update` failed with `The WIM is read-only` on every image — and
the loop printed "patched image 1..11" while doing nothing, because the exit
code was swallowed. `chmod u+w` first, and check `$?`.

**`wimlib-imagex replace` is not a subcommand** — it is `update`, which takes
commands on **stdin**, and the argument order is `add SOURCE DESTINATION`:

```bash
echo "add $W/hive/SYSTEM /Windows/System32/config/SYSTEM" | wimlib-imagex update wim.wim 1
```

Reversed arguments produce `Can't read metadata: No such file or directory`.

**`hivexsh` paths** — `cd /ControlSet001/Setup` fails; `cd Setup` works, because
`HKLM\Setup` is a root-level key. See syntax notes above.

**`pipefail` broke the `MoSetup` existence probe** — `hivexsh` exits non-zero on
a failed `cd`, so `hivexsh ... | grep -q 'not found'` returned non-zero regardless
of the grep result, and `add MoSetup` never ran. Capture to a variable first
(`probe=$( ... || true )`).

**`[ -n "$var" ] && echo ...` under `set -e`** returns non-zero when the variable
is empty, killing the script. Use an explicit `if`.

**`$HOME` expands to `/root` under `sudo`** — hardcoded absolute paths in
sudo-run scripts.

**QEMU under Wayland/Hyprland: `gtk initialization failed`** — sudo's
`env_reset` strips `DISPLAY` and `WAYLAND_DISPLAY`. Use `sudo -E`, or
`DISPLAY_MODE=sdl` as a fallback.

**`-display nographic` is invalid** — use `-nographic`. The script maps
`DISPLAY_MODE=nographic` correctly.

**`-device tpm-crb,tpm=` is wrong in QEMU 11.1** — the property is `tpmdev`:
`-device tpm-crb,tpmdev=tpm0`.

**`usb-tablet` needs an explicit controller on `q35`** — `-device
usb-tablet,bus=usb-bus.0` fails with `Bus 'usb-bus.0' not found`. Add
`-device qemu-xhci,id=xhci` and use `bus=xhci.0`.

**`-boot order=dc` boots the hard disk first** and silently ran the old NixOS
install instead of the installer. Order letters: `c` = first hard disk,
`d` = CD-ROM. Use `order=cd`.

**`--yes` was forwarded to QEMU** via a trailing `"$@"`, giving
`qemu-system-x86_64: --yes: invalid option`. Parse args explicitly and forward
only the remainder.

**`Authorization required, but no authorization protocol specified`** — harmless
sudo warning about a missing graphical askpass helper. `NOPASSWD: ALL` was in
effect and execution proceeded normally.

## Why not VFIO passthrough

`/sys/kernel/iommu_groups/` is empty and no `Intel-IOMMU` line appears in dmesg,
so PCI passthrough is unavailable. It is not needed: `-drive
file=/dev/nvme0n1,format=raw` plus `-device nvme` gives the guest a native NVMe
controller with O_DIRECT performance, without any hardware support.

Enabling VT-d in the BIOS and binding the device with `vfio-pci` would be
required for true passthrough, but many Lenovo Ideapad laptops lack PCI IOMMU
remapping in firmware, so it may be a hardware limit. Not worth pursuing unless
SMART access or native power management is needed.

## Cleanup

```bash
rm ~/Downloads/Win11_25H2_English_x64_v2*.iso    # frees 15.8 GB
rm -rf ~/.local/share/qemu-win11                 # OVMF vars + TPM state
```

Keep the original Win11 ISO while Win10 is unproven, in case the WIMs are worth
diffing.

## Files

| Path | |
|---|---|
| `~/qemu-win11.sh` | the installer script |
| `~/nvme_install_omarchy.md` | this document |
| `~/Downloads/Win10_22H2_English_x64v1.iso` | verified, in use |
| `~/Downloads/Win11_25H2_English_x64_v2.iso` | unverified provenance |
| `~/Downloads/Win11_25H2_English_x64_v2_patched.iso` | both WIMs patched; boot.wim fix never tested in Setup |
