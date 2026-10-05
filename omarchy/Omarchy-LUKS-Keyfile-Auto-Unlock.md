# Omarchy LUKS Keyfile Auto-Unlock

Boot Omarchy unattended: the encrypted root volume is unlocked from a keyfile
embedded in the initramfs, so no passphrase is typed at power-on. Useful for
remote access (RustDesk, Tailscale, etc.) where nobody is at the keyboard.

This replaces the older `Omarchy-LUKS-Keyfile-Auto-Unlock-Guide.md`, which had
two bugs that break on current Omarchy. See [Corrections to the old
guide](#corrections-to-the-old-guide).

---

## ⚠️ Security warning

This defeats the main thing LUKS protects against. The keyfile ships inside the
initramfs, which lives on the **unencrypted** ESP partition. Anyone with physical
access to the machine can extract it and unlock the disk without knowing your
passphrase.

Acceptable when the machine is in a reasonably secure location and you have a
recovery path. **Keep the original passphrase keyslot as a fallback** — do not
remove it.

If you need unattended boot *and* real protection against physical access, use a
TPM2 seal instead (`systemd-cryptenroll --tpm2-device=auto`), or store the
keyfile on a USB stick that must be plugged in at boot (see
[Alternative: USB keyfile](#alternative-usb-keyfile)).

---

## How it works

Three pieces, all of which must agree:

1. **A keyslot** in the LUKS header that accepts the keyfile.
2. **The keyfile in the initramfs**, added via an `mkinitcpio` drop-in.
3. **`cryptkey=rootfs:/path` on the kernel command line**, so the `encrypt` hook
   knows where to find it.

At boot, `mkinitcpio`'s `encrypt` hook tries `cryptsetup open --key-file` and
falls back to an interactive passphrase prompt only if that fails
(`/usr/lib/initcpio/hooks/encrypt:95-100`). With all three in place you get a
Plymouth splash and a login screen, no passphrase.

---

## Step 1: Identify the LUKS partition

```bash
lsblk -f | grep crypto_LUKS
blkid -s PARTUUID -o value /dev/nvme1n1p2
```

Use **your** device and PARTUUID. The examples below assume
`PARTUUID=4a368c7b-fd83-4504-bef2-5ffbb90efbc7`, which is this machine's value
and must be replaced on any other machine.

## Step 2: Create the keyfile

```bash
sudo dd if=/dev/urandom of=/root/luks.key bs=64 count=1
sudo chmod 400 /root/luks.key
```

64 bytes of entropy is what LUKS2 uses as key material here; the old guide's
`bs=4096 count=1` also works but wastes space. Keep it at `/root/luks.key` — the
path is baked into the initramfs and the cmdline.

## Step 3: Register the keyfile as a keyslot

```bash
sudo cryptsetup luksAddKey /dev/nvme1n1p2 /root/luks.key
```

Type your existing passphrase when prompted. Verify it works before going
further — this catches a bad passphrase or wrong device immediately:

```bash
sudo cryptsetup open --test-passphrase --key-file /root/luks.key /dev/nvme1n1p2 \
  && echo KEYFILE_OK || echo KEYFILE_FAIL
```

## Step 4: Add the keyfile to the initramfs

Do **not** edit `/etc/mkinitcpio.conf` directly. Omarchy layers its own drop-ins
into `/etc/mkinitcpio.conf.d/`, and `omarchy_hooks.conf` appends to `FILES`.
Write your own drop-in that sorts last so your `FILES+=` runs after theirs:

```bash
sudo tee /etc/mkinitcpio.conf.d/zz_luks_keyfile.conf >/dev/null <<'EOF'
# Embed the LUKS keyfile in the initramfs so the encrypt hook can unlock the
# root volume unattended, via cryptkey=rootfs:/root/luks.key on the kernel
# cmdline (see /etc/default/limine).
#
# Sorts last so this appends to the FILES array that omarchy_hooks.conf builds.
#
# SECURITY: the keyfile ships inside the initramfs on the *unencrypted* ESP, so
# anyone with physical access can extract it and unlock the root volume. This
# defeats the protection LUKS provides. The original passphrase keyslot is
# retained as a fallback.
FILES+=(/root/luks.key)
EOF
```

## Step 5: Add `cryptkey=` to the kernel command line

```bash
sudo nano /etc/default/limine
```

Append to the existing `KERNEL_CMDLINE[default]+=` line (do not create a second
one — Limine merges them, but keeping one line makes verification easier):

```
KERNEL_CMDLINE[default]+="cryptdevice=PARTUUID=YOUR-PARTUUID:root cryptkey=rootfs:/root/luks.key root=/dev/mapper/root zswap.enabled=0 rootflags=subvol=@ rw rootfstype=btrfs"
```

## Step 6: Rebuild

```bash
sudo limine-mkinitcpio
```

This is the only rebuild command you need. See
[Why `limine-mkinitcpio` and not `mkinitcpio -P`](#why-limine-mkinitcpio-and-not-mkinitcpio--p).

## Step 7: Verify before rebooting

All four checks should pass:

```bash
# 1. Every hash in limine.conf matches the file it points at
sudo bash -c '
while read -r line; do
  p="${line#path: boot():}"; f="${p%%#*}"
  case "$p" in *"#"*) ;; *) echo "no-hash $f"; continue;; esac
  h="${p##*#}"; a=$(b2sum -l 512 "/boot${f}" | cut -d" " -f1)
  [ "$a" = "$h" ] && echo "OK      $f" || { echo "MISMATCH $f"; echo "  want $h"; echo "  got  $a"; }
done < <(grep -E "^[[:space:]]*path: boot\(\):/" /boot/limine.conf)'

# 2. The keyfile is in the initramfs (Limine-era Omarchy has no standalone
#    initramfs file, so peek inside the UKI)
sudo python3 - <<'PY'
import struct, re
d = open("/boot/EFI/Linux/omarchy_linux-omarchy-bore.efi", "rb").read()
m = struct.unpack_from("<I", d, 0x3c)[0]
n = struct.unpack_from("<H", d, m + 6)[0]
so = m + 24 + struct.unpack_from("<H", d, m + 20)[0]
for i in range(n):
    name = d[so+i*40:so+i*40+8].rstrip(b"\0").decode()
    s = struct.unpack_from("<I", d, so+i*40+16)[0]
    o = struct.unpack_from("<I", d, so+i*40+20)[0]
    if name == ".cmdline":
        print("CMDLINE:", d[o:o+s].rstrip(b"\0").decode())
    if name == ".initrd":
        sub = d[o:o+s]
        t = sub.find(b"TRAILER!!!")
        mz = b"\x28\xb5\x2f\xfd"
        j = t
        while (k := sub.find(mz, j)) != -1:
            j = k + 1
        open("/tmp/ukicheck.zst", "wb").write(sub[k:])
PY
sudo bsdtar -tf /tmp/ukicheck.zst | grep -E '^root/|^hooks/encrypt$|^config$' && sudo rm -f /tmp/ukicheck.zst

# 3. The keyfile in the initramfs is byte-identical to the one in the LUKS header
sudo cryptsetup open --test-passphrase --key-file /root/luks.key /dev/nvme1n1p2 \
  && echo KEYFILE_OK

# 4. Both keyslots exist (passphrase + keyfile)
sudo cryptsetup luksDump /dev/nvme1n1p2 | grep -A1 '^Keyslots:\|^  [0-9]:'
```

## Step 8: Reboot and confirm

```bash
sudo reboot
```

You should see the Plymouth splash, then the login screen. No passphrase, no
`Press Y`. Press `Y` at the Limine menu means something is wrong — check
[Troubleshooting](#troubleshooting).

---

## Why `limine-mkinitcpio` and not `mkinitcpio -P`

This is the single most important part of this guide.

Omarchy boots a **unified kernel image** (a UKI: an EFI binary with the kernel,
the initramfs and the cmdline as PE sections). The UKI lives at
`/boot/EFI/Linux/omarchy_linux-<kernel-id>.efi` and the Limine config records a
**BLAKE2b-512 hash of that exact file** so Limine can verify it before booting.

`mkinitcpio -P` rebuilds initramfs images from presets in `/etc/mkinitcpio.d/`.
On Omarchy that directory is empty, and even if it does produce a UKI, it writes
the file **without updating the hash in `/boot/limine.conf`**. Same for
`limine-update`. Result:

```
WARNING: Blake2b hash for URI `...' does not match!
         Press Y to continue, press any other key to return to menu...
```

Because `/boot/limine.conf` sets `hash_mismatch_panic: no`, Limine degrades to
a warning plus a keypress prompt instead of refusing to boot. **This prompt is
the classic symptom of a stale hash, and it has nothing to do with LUKS.** Users
frequently misread it as a decryption problem and start re-doing the keyfile.

`limine-mkinitcpio` (the wrapper around
`/usr/share/libalpm/scripts/limine-mkinitcpio-install`) rebuilds the UKI and then
calls `limine-entry-tool --add-uki`, which recomputes the hash. One command,
hash stays in sync. It also runs automatically from pacman hooks, which is why
`pacman -S linux-omarchy-bore` works correctly while a manual `mkinitcpio -P`
does not.

Rule of thumb: **never run bare `mkinitcpio` on Omarchy. Use
`sudo limine-mkinitcpio`.**

## LUKS2 needs no `/etc/crypttab` entry

Root is unlocked entirely inside the initramfs by the `encrypt` hook, driven by
`cryptdevice=` and `cryptkey=` on the cmdline. `/etc/crypttab` stays empty. Only
add entries there for *additional* encrypted volumes that should unlock after
switch_root.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Press Y to continue` at the Limine menu | Stale BLAKE2b hash in `limine.conf` — **not** a LUKS problem | `sudo limine-mkinitcpio` |
| Still asks for a passphrase | Keyfile missing from initramfs, or `cryptkey=` absent from cmdline | Run both verification checks in Step 7 |
| `Keyfile could not be opened. Reverting to passphrase.` | `cryptkey=rootfs:` path does not match the keyfile's actual location in the initramfs | Check the `FILES+=(...)` path and the cmdline agree |
| `Invalid keyfile. Reverting to passphrase.` | Keyfile is in the initramfs but is not a registered keyslot | `cryptsetup luksAddKey` again, then rebuild |
| Boot fails after a kernel update | Hashes fine but the `cmdline` in `/etc/default/limine` was hand-edited and `limine-entry-tool` overwrote it | Re-check `/etc/default/limine`, then `sudo limine-mkinitcpio` |
| `limine-snapper-sync` reintroduces a stale hash | It re-emits entries from its own `snapshots.json` cache | Fix `snapshots.json` too, or just run `sudo limine-mkinitcpio` |

If you hit the stale-hash case and `limine-mkinitcpio` does not clear it (for
example the cached `snapshots.json` keeps winning), patch the recorded hash
directly. Back up first, then rewrite every occurrence of the stale hash with
the real one:

```bash
sudo cp -a /boot/limine.conf /boot/limine.conf.bak
sudo b2sum -l 512 /boot/EFI/Linux/omarchy_linux-omarchy-bore.efi   # the true hash
# replace OLD with the recorded hash, NEW with the b2sum output, in:
#   /boot/limine.conf
#   /boot/942726fc1a3b48ac95f89c0071607583/limine_history/snapshots.json
```

Then re-run the Step 7 hash check.

### Recovering from a bad boot

If the machine becomes unbootable, the passphrase keyslot is still there. Boot
from an Omarchy/Arch live USB, mount the ESP and root, comment out the
`cryptkey=` parameter in the Limine config or in `/proc/cmdline` on the boot
line, and boot with the passphrase. The keyslot was never removed.

---

## Removing the keyfile later

```bash
sudo cryptsetup luksRemoveKey /dev/nvme1n1p2   # prompts for the passphrase
sudo rm /etc/mkinitcpio.conf.d/zz_luks_keyfile.conf
# drop cryptkey= from /etc/default/limine
sudo limine-mkinitcpio
sudo shred -u /root/luks.key
```

`luksRemoveKey` needs at least one keyslot remaining, so you cannot remove the
last one this way. To remove the keyfile slot specifically, identify it with
`cryptsetup luksDump` (slots are numbered; the keyfile slot is the one added by
`luksAddKey`) and pass that number.

---

## Alternative: USB keyfile

Higher security: the keyfile lives on a USB stick, so an unattended boot still
requires physical possession of the stick.

```bash
# format a stick, ext4, and place the keyfile at its root
sudo mkfs.ext4 /dev/sdX1
sudo cp /root/luks.key /mnt/usb/luks.key
```

```
cryptkey=UUID=<usb-filesystem-uuid>:ext4:/luks.key
```

Trade-offs: the `encrypt` hook resolves the UUID at boot and must find the stick
before it can unlock root, so leave `rootdelay` at its default and make sure the
USB enumerates fast. `luksRemoveKey` semantics are unchanged.

## Alternative: TPM2 seal (best of both)

The keyfile never leaves the TPM, so a stolen disk is useless, and boot is still
unattended:

```bash
sudo systemd-cryptenroll --tpm2-device=auto /dev/nvme1n1p2
sudo initramfs-update      # on Omarchy: sudo limine-mkinitcpio
```

The PCR binding is what ties the sealed key to this machine. Requires the CPU to
have a TPM, and leaves the system dependent on firmware measurements staying
stable across BIOS updates.

---

## Corrections to the old guide

`Omarchy-LUKS-Keyfile-Auto-Unlock-Guide.md` had three problems:

1. **`mkinitcpio -P` + `limine-update` does not update Limine's recorded hash.**
   This is what caused the "press Y to boot" behaviour. Use `limine-mkinitcpio`.
2. **It told you to edit `/etc/mkinitcpio.conf`'s `FILES=` directly.** Omarchy
   layers drop-ins in `/etc/mkinitcpio.conf.d/` and `omarchy_hooks.conf` appends
   to `FILES`, so a hand edit there can be bypassed or clobbered by package
   updates. Use a `zz_`-prefixed drop-in.
3. **Its verification step, `lsinitcpio /boot/initramfs-linux.img`, cannot work
   on current Omarchy.** There is no standalone initramfs image; the initramfs is
   a PE section inside the UKI. Step 7 above extracts and lists it properly.

The keyfile-creation and `luksAddKey` steps in the old guide were fine.

---

## Reference

- `cryptkey=` — https://wiki.archlinux.org/title/Dm-crypt/System_configuration#cryptkey
- Keyfiles — https://wiki.archlinux.org/title/Dm-crypt/Device_encryption#Keyfiles
- `hash_mismatch_panic` — `/usr/share/doc/limine/CONFIG.md`
- Limine secure boot / hash enforcement — `/usr/share/doc/limine/USAGE.md`
- `encrypt` hook source — `/usr/lib/initcpio/hooks/encrypt`
- Omarchy rebuild script — `/usr/share/libalpm/scripts/limine-mkinitcpio-install`

Verified on Omarchy 4.0.0.r6720, Limine 12.9.1, mkinitcpio 42.2,
kernel 7.2.8-2-omarchy-bore.