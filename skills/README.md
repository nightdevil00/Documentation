# Agent skills

18 `SKILL.md` skills for working on an Omarchy / Arch Linux desktop, plus an
installer that drops them where your agents look for skills.

## Install

```bash
git clone https://github.com/nightdevil00/Documentation.git
cd Documentation/skills
./install.sh
```

`install.sh` puts a real copy of every skill in `~/.agents/skills/` — the
agent-agnostic directory Omarchy itself uses — then symlinks each one into the
other agent directories, so all agents share one copy:

```
~/.agents/skills/<name>          real directory — the source of truth
~/.claude/skills/<name>          -> symlink
~/.codex/skills/<name>           -> symlink
~/.pi/agent/skills/<name>        -> symlink
~/.gemini/config/skills/<name>   -> symlink
~/.hermes/skills/<name>          -> symlink
```

Restart your agent afterwards so it picks up the new skills.

### Options

| Flag | Effect |
| --- | --- |
| `./install.sh --list` | show the skills and where they land, change nothing |
| `./install.sh --dry-run` | print every action without writing |
| `./install.sh --force` | overwrite skills that already exist and differ |
| `./install.sh --no-mirror` | install only into `~/.agents/skills` |
| `./install.sh --uninstall` | remove these skills and their symlinks |

The script is idempotent — re-run it after a `git pull` and unchanged skills
are left alone.

## What it will and won't touch

`diagnose-crash` and `omarchy-app` ship with the `omarchy` package and are
never modified.

The **`omarchy`** skill *is* replaced, because this repo's copy is a superset:
upstream's `SKILL.md`, upstream's six topic guides (`capture.md`,
`contributing.md`, `hooks.md`, `hyprland.md`, `plugins.md`, `theming.md`), plus
a verified map of the CLI, config layering, and theming internals. The trade-off
is that it stops tracking `omarchy update`. The script prints the one-line
restore command when it does this:

```bash
rm -rf ~/.agents/skills/omarchy
ln -sfn /usr/share/omarchy/default/agents/skills/omarchy ~/.agents/skills/omarchy
```

If you edit a skill here, re-run `./install.sh` to push the change to
`~/.agents/skills`. Edit it in the repo, not in `~/.agents/skills`, or the next
install will overwrite your change.

## The skills

| Skill | What it covers |
| --- | --- |
| `omarchy` | the `omarchy` CLI, config layering, shell, hooks, toggles, updates |
| `omarchy-plugin` | authoring and validating shell plugins, the manifest schema |
| `omarchy-theme` | `colors.toml`, the palette resolver, `*.tpl` templating |
| `hyprland` | Hyprland 0.56 Lua config, window/workspace/layer rules, dispatchers |
| `quickshell` | QML shell toolkit: windows, IPC, IO, `qs.*` imports, gotchas |
| `sddm` | the greeter, sessions, PAM, autologin, the uwsm unit chain |
| `systemd` | units, drop-ins, journal, timers, user services, logind |
| `wayland-environment` | portals, XDG session env, per-app Wayland enablement |
| `arch` | pacman, AUR, boot, mkinitcpio, networking, audio, rollback |
| `bash` | strict-mode headers, quoting, arrays, ShellCheck, systemd/cron |
| `fish` | `config.fish`, scopes, lists, functions, POSIX translation |
| `python` | venvs, `uv`, `pyproject.toml`, typing, ruff, pytest, asyncio |
| `rust` | toolchains, Cargo, ownership, async, FFI, cross-compilation |
| `github` | git, `gh`, pull requests, Actions, security posture |
| `github-pages` | Pages, Jekyll, static generators, custom domains |
| `niri` | the Niri compositor — **not installed here**, portable reference |
| `noctalia` | the Noctalia shell — **not installed here**, portable reference |
| `caelestia` | the Caelestia shell — **not installed here**, portable reference |

The last three cover software that is not installed on the machine these were
written against (Hyprland + the Omarchy Quickshell). Each opens with an
"Applicability on this machine" section saying what actually applies here.

## Accuracy

Claims are grounded in a real install — Hyprland 0.56.2, Quickshell 0.3.1,
Omarchy 4.0.0.r6713, SDDM 0.21.0, Python 3.14.7, git 2.56.0, bash 5.3.20.

Every `omarchy` route cited was checked against `omarchy commands --all --json`
or by running it. Where a command is commonly misremembered, the skill says so —
for example `omarchy debug` does not exist; the report tool is the standalone
`omarchy-debug` binary, which Omarchy's own bundled skill also gets wrong.