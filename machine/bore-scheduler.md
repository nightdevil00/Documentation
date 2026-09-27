# BORE Kernel Setup — Omarchy

## Kernel Install

```bash
cd ~/Omarchy-20260927T155515Z-1-001/Omarchy
sudo pacman -U linux-omarchy-bore-7.2.7rc1-1-x86_64.pkg.tar.zst linux-omarchy-headers-7.2.7rc1-1-x86_64.pkg.tar.zst
```

## Fix NVIDIA DKMS (first attempt)

Wrong headers package installed — `linux-omarchy-headers` only provided headers for `7.2.7-1-omarchy-rc1`, not the bore variant. Bore kernel's `build` symlink was missing.

```bash
sudo pacman -U linux-omarchy-bore-headers-7.2.7rc1-1-x86_64.pkg.tar.zst --overwrite '/usr/lib/modules/7.2.7-1-omarchy-bore-rc1/build/*'
```

Conflict on `build` directory — removed and reinstalled:

```bash
sudo rm -rf /usr/lib/modules/7.2.7-1-omarchy-bore-rc1/build
sudo pacman -U linux-omarchy-bore-headers-7.2.7rc1-1-x86_64.pkg.tar.zst
```

DKMS auto-built nvidia on install post-hook. Then:

```bash
sudo mkinitcpio -P
```

## Optimizations Applied

### Bootloader params (`/etc/default/limine`)

```
KERNEL_CMDLINE[default]+="root=UUID=... zswap.enabled=0 rootflags=subvol=@ rw rootfstype=btrfs mitigations=off split_lock_detect=off preempt=full"
```

Ran `sudo limine-install` and `sudo limine-update` to regenerate `/efi/limine.conf`.

### Sysctl (`/etc/sysctl.d/99-gaming.conf` + fixed `/etc/sysctl.d/99-omarchy-sysctl.conf`)

```
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.core.netdev_max_backlog=5000
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
vm.compaction_proactiveness=1
vm.swappiness=10
vm.page_lock_unfairness=1
```

Overrode omarchy's `vm.swappiness=150` → `10`.

### Already optimal (no change needed)

- Root btrfs: `noatime,compress=zstd:3,ssd,discard=async`
- TCP congestion control: `bbr`
- `zswap.enabled=0` in cmdline

### Runtime (optional)

```bash
echo 0 | sudo tee /proc/sys/kernel/ksm/run
echo 1000000 | sudo tee /sys/kernel/debug/sched_ext/bore/latency
echo 500000 | sudo tee /sys/kernel/debug/sched_ext/bore/upscale_latency
sudo cset shield --cpu 4,5,6,7 --kthread=on
```

### Recommended packages

`gamescope`, `mangohud`, `gamemode` (enable `gamemoded`).

## Notes

- BORE kernel version: `7.2.7-1-omarchy-bore-rc1`
- Headers version: `7.2.7rc1-1`
- NVIDIA driver: `615.71.09` via DKMS
- Bootloader: Limine, managed by Omarchy's `limine-entry-tool`
- Re-run `sudo mkinitcpio -P` after any kernel update
