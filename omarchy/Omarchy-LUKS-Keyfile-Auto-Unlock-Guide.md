# Omarchy LUKS Keyfile Auto-Unlock Guide

**Complete step-by-step guide to automatically unlock LUKS full-disk encryption on Omarchy without typing a password at boot.**

This method embeds a keyfile inside the initramfs so the system can decrypt itself on startup. Useful for unattended boot (e.g. remote control via RustDesk).

---

## ⚠️ Security Warning

This method allows the system to boot **without asking for a password**.

Anyone with physical access to the disk can extract the keyfile from the initramfs (which lives on the unencrypted `/boot` partition) and unlock the LUKS volume.

Use this method **only** if:
- The machine is in a relatively secure location
- You need unattended boot for remote access
- You understand and accept the reduced physical security

**Recommendation**: Keep the original passphrase as a fallback.

---

## Prerequisites

- Omarchy already installed with LUKS encryption
- Root / sudo access
- Basic terminal knowledge

---

## Step 1: Identify the LUKS Partition

```bash
lsblk -f
```

Look for the partition with `TYPE="crypto_LUKS"`.  
Common examples: `/dev/nvme0n1p2` or `/dev/sda2`.

Note the device name (we will use `/dev/nvme0n1p2` as example).

Also get the **PARTUUID**:

```bash
blkid -s PARTUUID -o value /dev/nvme0n1p2
```

Copy the PARTUUID — you will need it later.

---

## Step 2: Create the Keyfile

```bash
sudo dd if=/dev/urandom of=/root/luks.key bs=4096 count=1
sudo chmod 400 /root/luks.key
```

**Explanation**:
- Generates 4 KB of high-entropy random data
- Restricts read permissions to root only

---

## Step 3: Add the Keyfile to LUKS

```bash
sudo cryptsetup luksAddKey /dev/nvme0n1p2 /root/luks.key
```

You will be prompted for the **current LUKS passphrase**.

After this step the volume can be unlocked with either:
- The original passphrase
- The new keyfile

---

## Step 4: Include the Keyfile in the Initramfs

Edit the mkinitcpio configuration:

```bash
sudo nano /etc/mkinitcpio.conf
```

Find the `FILES=` line and set it to:

```bash
FILES=(/root/luks.key)
```

If the line already contains other files, just append it:

```bash
FILES=(/some/other/file /root/luks.key)
```

Save and exit (`Ctrl+O` → Enter → `Ctrl+X`).

---

## Step 5: Configure Limine (Kernel Command Line)

Edit the Limine configuration:

```bash
sudo nano /etc/default/limine
```

Locate the line starting with `KERNEL_CMDLINE[default]=`.

Modify it so it includes the `cryptkey` parameter.  
Example (replace with your actual PARTUUID):

```bash
KERNEL_CMDLINE[default]="cryptdevice=PARTUUID=YOUR-PARTUUID-HERE:root cryptkey=rootfs:/root/luks.key root=/dev/mapper/root zswap.enabled=0 rootflags=subvol=@ rw rootfstype=btrfs"
KERNEL_CMDLINE[default]+="quiet splash"
```

**Critical part**:
```
cryptkey=rootfs:/root/luks.key
```

Save and exit.

---

## Step 6: Rebuild Initramfs and Update Limine

```bash
sudo mkinitcpio -P
sudo limine-update
```

> Note: If `limine-update` is not available, try `sudo limine-install` or simply reboot — Limine often regenerates automatically on next boot.

---

## Step 7: Reboot and Test

```bash
sudo reboot
```

If everything was configured correctly, the system should boot **without asking for the LUKS passphrase**.

---

## Verification Commands (Optional but Recommended)

### Check that the keyfile is inside the initramfs

```bash
lsinitcpio /boot/initramfs-linux.img | grep luks.key
```

### View LUKS key slots

```bash
sudo cryptsetup luksDump /dev/nvme0n1p2
```

You should see at least two key slots (one for the passphrase, one for the keyfile).

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Still asked for password | Double-check `cryptkey=rootfs:/root/luks.key` in `/etc/default/limine` and regenerate with `mkinitcpio -P` + `limine-update` |
| System does not boot | Boot from Omarchy/Arch live USB, mount the partitions, and verify the configuration files |
| Want to remove the keyfile later | Use `sudo cryptsetup luksRemoveKey /dev/nvme0n1p2` and remove the entry from `FILES=` and the kernel cmdline |

---

## Alternative: USB Keyfile (More Secure)

If you prefer not to embed the keyfile in the initramfs, you can store it on a USB stick instead.

The kernel parameter would look like:

```
cryptkey=UUID=USB-UUID:ext4:/luks.key
```

This requires the USB to be plugged in at boot time and is slightly more secure against casual physical access.

---

## Official Documentation References

- [Arch Wiki – Keyfiles](https://wiki.archlinux.org/title/Dm-crypt/Device_encryption#Keyfiles)
- [Arch Wiki – cryptkey parameter](https://wiki.archlinux.org/title/Dm-crypt/System_configuration#cryptkey)
- [Omarchy Security Manual](https://omarchy.org/manual/security/)

---

**Guide created for Omarchy (Arch-based)**  
Last updated: September 2026
