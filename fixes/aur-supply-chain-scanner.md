# Atomic Arch Infection Checker

Scans an Arch Linux system for indicators of compromise (IOCs) associated with the **Atomic Arch** supply-chain attack on the Arch User Repository (AUR), which compromised **1,500+ packages** starting June 11, 2026, delivering a Rust infostealer and eBPF rootkit, and a subsequent **coordinated campaign** on July 30, 2026 confirming **182+ additional compromised package bases** delivering a cross-platform downloader/persistence loader.

## Features

- Checks installed AUR packages against a known-infected package list (auto-updated from 4 remote sources)
- Detects malicious npm/bun/pnpm/yarn packages (`atomic-lockfile`, `lockfile-js`, `js-digest`, `ansi-colors`, `nextfile-js`) globally, in `.INSTALL` hooks, npm/bun/pnpm cache, and shell configs
- Scans for eBPF rootkit artifacts, including known malicious pinned maps (`hidden_pids`, `hidden_names`, `hidden_inodes`)
- Detects hidden processes (present in `/proc` but hidden from `ps`)
- Identifies suspicious systemd services, including non-package services with `Restart=always`
- Checks for established connections on suspicious ports and known C2 infrastructure (`temp.sh`, known Atomic Arch and July 30 campaign Tor onion addresses)
- Scans pacman logs for known-infected packages
- Detects `/etc/ld.so.preload` injection
- Flags executables running from volatile paths (`/tmp`, `/dev/shm`, `/var/tmp`, deleted binaries)
- Scans user-level persistence mechanisms (systemd, autostart, pacman hooks)
- Detects shell config injection (`curl|bash`, `LD_PRELOAD`, `bun add`/`pnpm add`/`yarn add`, base64 decoding)
- Checks npm/bun/pnpm/yarn global packages for suspicious install hook scripts
- Reports SSH authorized_keys presence and forced-command keys
- Scans for Atomic Arch persistence artifacts (deps ELF, `/var/lib` binaries, cryptominer staging)
- **Scans kernel modules** for suspicious names and non-standard paths
- **Audits `/etc/hosts`** for tampered entries redirecting security domains
- **Scans SUID/SGID binaries** for non-root ownership and unusual locations
- **Checks npm/bun runtime presence** and warns if the npm/bun supply-chain vector is exploitable
- **Auto-updates** the infected package list from remote sources at each run
- Supports **JSON output** (`--json`) for machine-readable results
- Supports **desktop notifications** via `notify-send` (mako/dunst)
- Can be installed as a **systemd timer** for periodic background scanning
- Static **PKGBUILD security analysis** to check for malicious patterns before running `makepkg`

## Usage

```bash
# One-time scan (no install needed)
./check-atomic-arch_new.sh

# Output results as JSON (machine-readable, for tooling/automation)
./check-atomic-arch_new.sh --json

# Install as systemd user service + timer (runs at boot, then every 6h)
./check-atomic-arch_new.sh --install

# Remove the systemd service/timer
./check-atomic-arch_new.sh --remove

# Run in daemon mode (used internally by systemd service)
./check-atomic-arch_new.sh --daemon

# Static security analysis of a PKGBUILD file (before running makepkg)
./check-atomic-arch_new.sh --check-pkgbuild PKGBUILD
```

## Checks Performed (18 + PKGBUILD check)

| # | Check | Description |
|---|-------|-------------|
| 1 | Known-infected AUR packages | Matches `pacman -Qqm` against the infected package list |
| 2 | Malicious npm/bun/pnpm/yarn packages | Detects `atomic-lockfile`, `lockfile-js`, `js-digest`, `ansi-colors`, `nextfile-js` globally, in `.INSTALL` files, npm/bun/pnpm cache; flags obfuscated hex/octal escapes and `bun add`/`pnpm add`/`yarn add` in `.INSTALL` hooks |
| 3 | eBPF artifacts | Scans `/sys/fs/bpf` for known malicious pinned maps (`hidden_pids`, `hidden_names`, `hidden_inodes`) and runs `bpftool` for suspicious programs |
| 4 | Hidden processes | Finds PIDs in `/proc` that `ps` cannot see |
| 5 | Suspicious services | Detects services named `rat` or `systemd-initd`; flags non-package services with `Restart=always` |
| 6 | Network connections | Flags established TCP connections on suspicious ports; checks for connections to `temp.sh` (exfiltration) and known Tor C2 addresses (Atomic Arch + July 30 campaign) |
| 7 | Pacman log analysis | Cross-references pacman log with installed infected packages |
| 8 | ld.so.preload | Detects shared library injection |
| 9 | Volatile executables | Finds processes running from temp paths or with deleted binaries |
| 10 | User persistence | Scans systemd user units, autostart files, and pacman hooks |
| 11 | Shell config injection | Detects `curl|bash`, `LD_PRELOAD`, `bun add`/`pnpm add`/`yarn add`, and base64 decode patterns |
| 12 | npm/bun/pnpm/yarn hook scripts | Inspects global npm/bun/pnpm/yarn packages for suspicious install scripts |
| 13 | SSH authorized_keys | Reports number of keys and detects forced-command keys |
| 14 | Atomic Arch persistence artifacts | Scans npm cache for deps ELF, `/var/lib` for suspicious ELF binaries referencing Atomic Arch strings, and detects unowned `monero-wallet-gui` (cryptominer staging) |
| 15 | Kernel modules | Scans loaded kernel modules for suspicious names (`hide`, `rootkit`, `stealth`, etc.) and modules loaded from non-standard paths |
| 16 | /etc/hosts tamper detection | Checks for suspicious entries redirecting known domains to localhost or to suspicious IP ranges |
| 17 | SUID/SGID binary audit | Scans for unexpected SUID/SGID binaries outside standard paths or with non-root ownership |
| 18 | npm/bun runtime presence | Reports whether npm/bun is installed; if neither is present, the npm/bun supply-chain vector cannot be exploited locally |
| — | PKGBUILD check | Run via `--check-pkgbuild <file>` — static analysis of a PKGBUILD for malicious patterns before installation |
| — | JSON output | Run via `--json` — outputs all results as structured JSON for integration with monitoring/alerting pipelines |

## PKGBUILD Security Check

The `--check-pkgbuild <file>` flag performs a static pattern-based analysis of a PKGBUILD file, mirroring the checks from [pkgbuild-check](https://github.com/kkub11/pkgbuild-check). It examines the file for:

**Critical issues** (red):
- Remote code execution via `curl|sh` / `wget|bash` pipes
- Obfuscated execution (`base64` + `eval`)
- Reverse shell patterns (`/dev/tcp`, `nc -e`, etc.)
- Cron/systemd persistence injection
- SSH `authorized_keys` modification
- `/etc/passwd` / `/etc/shadow` tampering
- `rm -rf` on system paths outside `$pkgdir`
- Cryptocurrency miner signatures (xmrig, stratum+tcp, monero)
- `LD_PRELOAD` injection outside `$pkgdir`
- Binary download + immediate execution

**Warnings** (yellow):
- `SKIP` in checksum arrays
- Weak checksums (`md5sums`, `sha1sums`)
- Plain HTTP source URLs
- External scripts sourced at build time
- Untagged VCS sources (`master`/`main`/`HEAD`)
- `.install` script present
- World-writable `chmod`
- `sudo`/`su` in build functions

**Good practices** (green):
- Strong checksum (`b2sums`/`sha256sums`/`sha512sums`)
- `$pkgdir` used in `package()`
- `DESTDIR=$pkgdir` with `make install`
- PGP key verification (`validpgpkeys`)
- License field declared
- `install -Dm` for file placement
- Maintainer comment present

Exit codes: `0` (clean), `2` (critical issues found).

```bash
# Only build if the PKGBUILD passes
./check-atomic-arch_new.sh --check-pkgbuild PKGBUILD && makepkg -si
```

## Results

- **PASS** — No indicators found
- **WARN** — Minor findings (suspicious network ports, SSH keys present)
- **FAIL** — Indicators of compromise confirmed

If any FAIL occurs, the system should be treated as fully compromised. Recommended actions: back up data, perform a clean reinstall, and rotate all credentials (GitHub, SSH, vaults, browser sessions, messaging tokens).

## JSON Output

When run with `--json`, the script outputs a structured JSON object to stdout (informational messages go to stderr). Schema:

```json
{
  "schemaVersion": "1.0",
  "startTime": "2026-07-01T12:00:00+00:00",
  "endTime": "2026-07-01T12:00:30+00:00",
  "script": "check-atomic-arch_new.sh",
  "checks": [
    {
      "id": 1,
      "name": "Known-infected AUR packages",
      "status": "PASS",
      "detail": ""
    }
  ],
  "summary": {
    "pass": 18,
    "warn": 0,
    "fail": 0,
    "total": 18
  },
  "verdict": "CLEAN"
}
```

Status values: `PASS`, `WARN`, `FAIL`. Verdict values: `CLEAN`, `WARNINGS`, `COMPROMISED`.

## Remote Update

The script fetches the latest known-infected package list from 4 community-maintained remote sources at each run:

1. `lenucksi/aur-malware-check` (consolidated list, 1,619+ packages)
2. `quantenProjects` Gist
3. CSCS pastebin
4. Arch Linux HedgeDoc

If remote fetch fails, it falls back to the bundled `list.txt` in the same directory as the script. The local fallback is updated periodically — as of **2026-07-30** it contains **2,115 known-infected packages** (covering both the June 2026 Atomic Arch campaign and the July 30, 2026 coordinated campaign).

## Sources & References

The script was updated against analysis from the following articles and documents (June 2026):

- **Sonatype** — "Atomic Arch" campaign naming, `atomic-lockfile` / `lockfile-js` npm analysis, CVSS 8.7
- **RedEye Security** — Attack mechanics (orphan adoption, commit forgery), payload analysis, eBPF rootkit capabilities, credential targeting scope
- **Rescana** — 1,500+ package compromise, MITRE ATT&CK mapping, CI/CD runner risk, technical mitigations
- **Breached.Company** — Multi-wave attack timeline, npm-to-AUR cross-ecosystem risk, eBPF rootkit cleanup implications
- **Threat-Modeling.com** — Organizational impact assessment, Steam Deck risk, CI/CD pipeline exposure
- **Latest Hacking News** — Second wave details (bun/js-digest variant), persistence via systemd `Restart=always`, onion C2
- **Cybersecurity News** — Initial 400+ package disclosure, PKGBUILD injection technique, rootkit persistence tactics
- **Anavem** — Six-month attack timeline, kernel-level rootkit persistence, cryptocurrency wallet targeting
- **lenucksi/aur-malware-check** — Consolidated community detection scripts, IOC registry, malicious npm package list, HedgeDoc package list
- **ioctl.fail** — Preliminary technical analysis, deps binary reverse engineering, eBPF rootkit internals
- **IFIN Discourse** — Second wave (js-digest SHA256, bun variant), attack summary
- **Arch Linux aur-general ML** — Maintainer discussion, cleanup coordination, arojas impersonation clarification by David Runge
- **Privacy Guides** — Second wave estimate of 1,500+ compromised packages
- **StepSecurity** — PKGBUILD injection analysis, orphan adoption exploitation
- **Socket.dev** — `atomic-lockfile` / `js-digest` package metadata and download counts
- **Firstp1ck (GitHub Gist)** — July 30, 2026 coordinated campaign analysis: 182 confirmed package bases with cross-platform downloader/persistence loader, new Tor C2 (`p4ayykxcrxfyzrgfbbkazernntjbz43hgclrheguylzd7kijmtce6zqd.onion`), ChaCha20-obfuscated payload (SHA-256 `e73a35b3e75e94746428d1a207703d6335933deadee7d1d9c9d0328df7b9df77`)

## Pacman Hook: Block Installation of Infected Packages

A `PreTransaction` pacman hook intercepts every package install/upgrade — from pacman, yay, paru, or any other tool — and aborts the transaction if the package is in the blocked list.

### Files

| File | Purpose |
|------|---------|
| `/etc/pacman.d/hooks/aur-malware.hook` | Hook trigger — fires on every Install/Upgrade |
| `/usr/local/bin/aur-malware-check.sh` | Check script — reads blocked list, aborts if match |
| `/etc/aur-malware/list.txt` | Blocked package list |

### Install

```bash
sudo ./install-hook.sh              # uses list.txt next to the script
sudo ./install-hook.sh /path/to/list.txt  # custom path
```

Run it again anytime to update the blocked list. No hook reload needed — the script reads the file fresh each transaction.

### How it works

Every time any package manager installs or upgrades a package, pacman fires the hook. The check script reads the matched package names from stdin and compares them against the blocked list. On a match, the transaction is aborted with an error. No wrapper, no alias — covers everything.

## Platform

Arch Linux (AUR-focused). Requires `bash`, `pacman`, and optional `systemd --user` for the timer/notification features.
