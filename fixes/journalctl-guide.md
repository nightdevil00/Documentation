# journalctl Field Guide

A practical cheat sheet for reading system logs on Linux (systemd).

## Basics

```bash
journalctl                     # all logs, oldest first (in $PAGER)
journalctl -r                  # newest first
journalctl -f                  # follow live (like tail -f)
journalctl -e                  # jump to the end
journalctl --no-pager ...      # print raw, good for pipes
journalctl --disk-usage        # how much space logs take
```

### Time filtering

```bash
journalctl --since "1 hour ago"
journalctl --since today
journalctl --since "2026-08-20 09:00" --until "2026-08-20 12:00"
journalctl -n 100              # last 100 lines
```

### Filtering by unit, priority, boot

```bash
journalctl -u NetworkManager           # one systemd unit
journalctl -u NetworkManager -u wpa_supplicant   # several at once
journalctl --user -u pipewire          # your own user services
journalctl -p err                      # priority: 0 emerg .. 3 err .. 7 debug
journalctl -p warning..alert           # range
journalctl -b                          # current boot only
journalctl -b -1                       # previous boot
journalctl --list-boots                # index of boots
journalctl -p 3 -xb                    # errors, this boot, end of log
systemctl --failed                     # what units died
```

### Searching by fields

```bash
journalctl _COMM=sshd                   # by executable
journalctl _PID=1234                    # by process id
journalctl _SYSTEMD_UNIT=gdm.service
man systemd.journal-fields              # full field reference
```

### Output formats

```bash
journalctl -o json-pretty               # machine readable
journalctl -o short-precise             # microsecond timestamps
journalctl -u foo -o cat                # message only, no metadata
journalctl -o json-pretty -u pipewire | jq .MESSAGE
```

## Kernel, drivers, hardware

`-k` = kernel ring buffer (same source as `dmesg`, but persistent across boots):

```bash
journalctl -k                           # kernel msgs, current boot
journalctl -k -b -1                     # kernel msgs from previous boot
journalctl -k | grep -iE 'error|fail|firmware'    # driver/firmware complaints
journalctl -k | grep -iE 'usb'          # plug/unplug events (great with -f)
journalctl -u systemd-udevd             # device enumeration/hotplug daemon
```

## Keyboard / input

```bash
# watch while plugging the keyboard in:
journalctl -kf | grep -iE 'hid|input|keyboard|usb'

# did the device even enumerate? look for vendor/product id
journalctl -k -b | grep -i 'new.*device\|hid-generic'

# stuck modifier keys / ghost input often show in the compositor:
journalctl --user -b | grep -iE 'mutter|kwin|sway|hyprland'
```

Tip: no log lines on plug = cable/port/power issue; lines but no keys = driver/config issue.

## Audio

```bash
journalctl --user -u pipewire -u pipewire-pulse -u wireplumber -b
journalctl -k | grep -i alsa            # low-level codec/sound-card errors
journalctl --user -u pipewire -f        # follow while reproducing the issue
```

PipeWire/WirePlumbber logs are per-user — forgetting `--user` shows nothing.

## Video / GPU

```bash
journalctl -b | grep -iE 'drm|i915|xe|amdgpu|radeon|nouveau|nvidia'
journalctl -b -1 | grep -iE 'gpu|drm'   # was last crash GPU-related?
journalctl -u gdm                       # or sddm/lightdm — display manager
journalctl -b | grep -iE 'wayland|xorg|mutter|kwin'
```

## Network

```bash
journalctl -u NetworkManager -b         # wifi/eth events, DHCP, disconnects
journalctl -u wpa_supplicant            # auth failures, roaming
journalctl -u systemd-networkd -u systemd-resolved   # if not using NM
journalctl -k | grep -iE 'iwlwifi|ath|rtl|link (is )?(up|down)|eth|wlan'
journalctl -u firewalld -u nftables -u ufw   # firewall blocks
```

## Disk / storage

```bash
journalctl -k | grep -iE 'ata[0-9]|nvme|scsi|reset|I/O error'
journalctl -b -p err                    # any error incl. fs problems
journalctl -u fstrim -u smartd          # trim / health monitoring if enabled
```

## Crashes

```bash
coredumpctl list                        # everything that segfaulted
coredumpctl info <pid>                  # backtrace of one crash
coredumpctl gdb <pid>                   # open it in a debugger
journalctl -b -1 -e                     # final lines before last reboot/crash
```

## Maintenance

```bash
sudo journalctl --vacuum-size=500M      # cap total size
sudo journalctl --vacuum-time=30d       # keep only 30 days
# make logs survive reboots: ensure /var/log/journal exists
# and Storage=persistent (or auto) in /etc/systemd/journald.conf
```

## Everyday one-liners

```bash
journalctl -f                            # what is happening right now?
journalctl -p 3 -xb                      # real errors from this boot
journalctl --since "-15min" --no-pager   # last 15 minutes, plain text
journalctl -b -1 -p err --no-pager       # why did the last session go wrong?
```
