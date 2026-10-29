# Fingerprint setup — Goodix 27C6:55A4 on Arch Linux (Omarchy/Hyprland)

Everything that was done to get the fingerprint sensor working on this machine,
documented. Machine: Arch Linux (Omarchy 4.5.0rc2 base), Hyprland + SDDM,
ELAN/Goodix fingerprint sensor (ultimately identified as the **Goodix FingerPrint
Device**, USB `27c6:55a4`).

---

## 1. The sensor

```
$ lsusb | grep -i -E 'goodix|finger|fingerprint|elan|synapt'
Bus 001 Device 003: ID 27c6:55a4 Shenzhen Goodix Technology Co.,Ltd.
    Goodix FingerPrint Device
```

Earlier investigation had chased an ELAN sensor (I2C HID, `0018:04F3:3140`) — that
was a red herring. `lsusb` after installing `usbutils` confirmed the real device:
**Goodix FingerPrint Device, USB ID `27c6:55a4`** (ThinkBook 15 G2 ITL class of
hardware; also ThinkPad E14/E15, IdeaPad 3 14, ZHAOYANG K4e).

`omarchy-hw-fingerprint` exits 0 → the hardware is seen.

## 2. Root cause

The stock `libfprint` driver set does **not** contain a driver for this device:

```
$ fprintd-list mihai
No devices available

$ G_MESSAGES_DEBUG=all fprintd   # / our test client
libfprint-context-DEBUG: No driver found for USB device 27C6:55A4
```

The upstream `goodixmoc` driver only knows PIDs such as `0x6092`, `0x609A`, `0x60BC`,
`0x60C2`, `0x6582`, `0x66A9`, … — **not `0x55A4`**. The Goodix 55x4 speaks a
TLS-PSK based protocol (Goodix command set `GF…/TLS`, `GOODIX_55X4_*`), which no
stock distro libfprint shipped. The Fedora COPR / AUR `libfprint-goodixtls-55x4`
and the community fork by *Hydrogell* fill this gap.

## 3. The fix — patched libfprint

Patched driver source: <https://github.com/Hydrogell/goodix-27c6-55a4-fingerprint-linux>
(patch `patches/55a4-driver.patch` on top of
<https://github.com/TheWeirdDev/libfprint> branch `55b4-experimental`,
pinned to commit `d1ca62a801aa565e67d1a2a47aaa7a33232b7990`).

Build/install procedure used:

```bash
# deps (as root on Arch)
pacman -S --needed --noconfirm git curl base-devel meson ninja gcc pkg-config \
        glib2 libgusb nss openssl cairo pixman opencv doctest python python-virtualenv

# build
git clone -q --branch 55b4-experimental https://github.com/TheWeirdDev/libfprint.git
git -C libfprint checkout -q d1ca62a801aa565e67d1a2a47aaa7a33232b7990
git clone -q https://github.com/Hydrogell/goodix-27c6-55a4-fingerprint-linux.git
git -C libfprint apply goodix-27c6-55a4-fingerprint-linux/patches/55a4-driver.patch
cd libfprint
meson setup _build -Ddrivers=goodixtls55x4 -Dintrospection=false -Ddoc=false
ninja -C _build

# install into /opt and point fprintd at it
sudo install -m755 _build/libfprint/libfprint-2.so.2.0.0 /opt/libfprint-goodix/lib64/
sudo tee /etc/systemd/system/fprintd.service.d/10-goodix55a4.conf > /dev/null <<EOF
[Service]
Environment=LD_LIBRARY_PATH=/opt/libfprint-goodix/lib64
EOF
sudo systemctl daemon-reload
sudo systemctl restart fprintd
```

Two environment issues had to be worked around during the build on this machine:

- `glib-mkenums` is in the split package **`glib2-devel`** (`pacman -S glib2-devel`).
- sigfm requires pkg-config name `opencv4`; this system ships OpenCV 5 (`opencv5.pc`),
  so an alias was created: `cp /usr/lib/pkgconfig/opencv5.pc /usr/lib/pkgconfig/opencv4.pc`.

## 4. One-time TLS key provisioning

The driver speaks TLS-PSK with an all-zero key; the sensor must be provisioned once
with the white-box blob:

```bash
git clone https://github.com/goodix-fp-linux-dev/goodix-fp-dump.git
git -C goodix-fp-dump checkout -q cc43bb3b3154a0bccc0412ae024013c7e1923139
python3 -m venv goodix-fp-dump/.venv
goodix-fp-dump/.venv/bin/pip install -q pyusb crcmod python-periphery
printf 'class SpiDev:\n    pass\n' > goodix-fp-dump/spidev.py
cp goodix-27c6-55a4-fingerprint-linux/scripts/provision_psk.py goodix-fp-dump/
systemctl stop fprintd; pkill -TERM -x fprintd; sleep 2
cd goodix-fp-dump && PYTHONDONTWRITEBYTECODE=1 ./.venv/bin/python provision_psk.py
# → "key written and verified"
systemctl restart fprintd
```

## 5. Reliability guards

- `/etc/systemd/system/fprintd-sleep-fix.service` (stop fprintd before sleep,
  restart on resume) + enabled.
- `/etc/systemd/system/fprintd.service.d/20-goodix-runtime-max.conf`:
  `RuntimeMaxSec=600`.
- `/etc/systemd/system/fprintd.service.d/10-stop-timeout.conf`: `TimeoutStopSec=3s`.
- `/etc/udev/rules.d/61-goodix-no-autosuspend.rules`:
  `ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="27c6", ATTR{idProduct}=="55a4", ATTR{power/control}="on"`

## 6. Enrollment and verification

```bash
fprintd-list mihai
# found 1 devices
# Fingerprints for user mihai on Goodix TLS Fingerprint Sensor 55X4 (press):
#  - #0: right-index-finger

sudo fprintd-enroll mihai        # 16 touches; first run got 'enroll-disconnected' → retried → OK
# → "Enroll result: enroll-completed"

sudo fprintd-verify mihai        # NOTE: pass the real username; sudo defaults to root
# → Listing enrolled fingers:
#    - #0: right-index-finger
# → Verify started!
# → Verify result: verify-… (done)
```

The verify pipeline engages the driver (FDT mode switch, image capture, frame
averaging) and talks to the hardware.

## 7. PAM wiring (Omarchy official scripts)

```bash
OMARCHY_PATH=/usr/share/omarchy sudo /usr/share/omarchy/bin/omarchy-apply-lock
# → configures /etc/pam.d/omarchy-lock-password, /etc/pam.d/omarchy-lock-fingerprint
#   (auth required pam_fprintd.so), resume hook, stop timeout; only writes the
#   fingerprint lock stack when fprintd-list shows enrolled `-#…` entries.
```

- `/etc/pam.d/sudo`:

```
#%PAM-1.0
auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      sufficient pam_fprintd.so
auth		include		system-auth
account		include		system-auth
session		include		system-auth
session   	optional	pam_systemd.so class=none
```

- `/etc/pam.d/polkit-1`:

```
auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      sufficient pam_fprintd.so
auth      include system-auth

account   include system-auth
password  include system-auth
session   include system-auth
```

- `/etc/pam.d/omarchy-lock-fingerprint` (written by `omarchy-apply-lock` after
  successful enrollment):

```
#%PAM-1.0
auth       required                    pam_fprintd.so
account    include                     system-local-login
```

## 8. Packages involved (runtime)

- `fprintd` 1.94.5-2 (daemon; D-Bus `net.reactivated.Fprint`)
- `libfprint-git` (`libfprint-2.so.2` — stock, unused for this device now; replaced
  functionally by the /opt build)
- `usbutils` (lsusb)

## 9. Packages needed to build the patched libfprint (build only)

- `git`, `curl`, `base-devel`, `meson`, `ninja`, `gcc`, `pkg-config`
- `glib2` + **`glib2-devel`** (contains `glib-mkenums`), `libgusb`, `nss`, `openssl`,
  `cairo`, `pixman`, `opencv`, `doctest`, `python`, `python-virtualenv`
- OpenCV (5.x here) + pkg-config alias `opencv4.pc`

## 10. Rollback

```bash
sudo bash uninstall.sh     # from the goodix-27c6-55a4-fingerprint-linux repo
# removes /opt/libfprint-goodix, fprintd drop-ins, sleep-fix unit, udev rule;
# reverts fprintd to the stock libfprint.
```

---

## 11. Local copies of the needed packages (this folder)

- `goodix-27c6-55a4-fingerprint-linux/` — installer + patch + scripts
- `libfprint/` — patched libfprint fork (branch `55b4-experimental`)
- `goodix-fp-dump/` — TLS key provisioning tool (`provision_psk.py`, `driver_55x4.py`)
