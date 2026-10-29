# fingerprint-goodix

Documentation and local package sources for getting the Goodix `27c6:55a4`
fingerprint sensor working on Arch Linux (Omarchy/Hyprland).

- `DOCUMENTATION.md` — full write-up of the fix, build steps, provisioning,
  enrollment, PAM wiring, packages and rollback.

## Downloaded packages / sources

- `libfprint/` — patched libfprint fork (`TheWeirdDev/libfprint`, branch
  `55b4-experimental`, pinned `d1ca62a…`)
- `goodix-27c6-55a4-fingerprint-linux/` — installer + `55a4-driver.patch` +
  provisioning scripts
- `goodix-fp-dump/` — `goodix-fp-linux-dev/goodix-fp-dump` (TLS key provisioning)
