#!/usr/bin/env bash
#
# install.sh — install the Omarchy/Arch agent skills in this repo.
#
#   ./install.sh                 install (copy to ~/.agents/skills, symlink the rest)
#   ./install.sh --dry-run       show what would happen, change nothing
#   ./install.sh --force         replace skills that already exist
#   ./install.sh --no-mirror     install only into ~/.agents/skills
#   ./install.sh --list          list the skills in this repo and where they land
#   ./install.sh --uninstall     remove the skills this repo installed
#
# Layout after install:
#
#   ~/.agents/skills/<name>            real directory — the single source of truth
#   ~/.claude/skills/<name>            -> symlink to the above
#   ~/.codex/skills/<name>             -> symlink
#   ~/.pi/agent/skills/<name>          -> symlink
#   ~/.gemini/config/skills/<name>    -> symlink
#   ~/.hermes/skills/<name>            -> symlink
#
# Canonical dir is ~/.agents/skills — that is the agent-agnostic path, and the
# one Omarchy itself uses. Every other agent dir points at it, so there is only
# ever one copy of a skill to keep in sync.
#
# Skills owned by the omarchy package (diagnose-crash, omarchy-app) are never
# touched. The `omarchy` skill IS replaced, because this repo's copy is a
# superset: upstream's SKILL.md plus upstream's six topic guides plus the
# verified CLI/config internals. Your previous symlink is printed as a restore
# command on completion.

set -euo pipefail

# --- locate the skills directory (works from a clone, a symlink, or a copy) ---
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SKILLS_DIR="$SCRIPT_DIR"

CANONICAL="${AGENTS_SKILLS_DIR:-$HOME/.agents/skills}"
MIRRORS=(
  "$HOME/.claude/skills"
  "$HOME/.codex/skills"
  "$HOME/.pi/agent/skills"
  "$HOME/.gemini/config/skills"
  "$HOME/.hermes/skills"
)

# Skills shipped by the omarchy package. Never overwrite, never remove.
PROTECTED="diagnose-crash omarchy-app"
OMARCHY_PKG_SKILL="/usr/share/omarchy/default/agents/skills/omarchy"

DRY_RUN=0
FORCE=0
MIRROR=1
ACTION="install"

# --- output helpers -----------------------------------------------------------
if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else
  B=""; DIM=""; G=""; Y=""; R=""; N=""
fi
info() { printf '%s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" -eq 1 ]; then printf '    %s would run:%s %s\n' "$DIM" "$N" "$*"; else "$@"; fi; }

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#$//' | sed '/^set -euo/q'
  exit 0
}

# --- args ---------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run)  DRY_RUN=1 ;;
    -f|--force)    FORCE=1 ;;
    --no-mirror)   MIRROR=0 ;;
    --uninstall)   ACTION="uninstall" ;;
    -l|--list)     ACTION="list" ;;
    -h|--help)     usage ;;
    *)             die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

# --- discover skills ----------------------------------------------------------
[ -d "$SKILLS_DIR" ] || die "no skills directory at $SKILLS_DIR"

skills=()
for entry in "$SKILLS_DIR"/*/; do
  [ -d "$entry" ] || continue
  name="${entry%/}"; name="${name##*/}"
  [ "$name" = "assets" ] && continue
  [ -f "$entry/SKILL.md" ] || continue
  case " $PROTECTED " in *" $name "*) continue ;; esac
  skills+=("$name")
done
[ "${#skills[@]}" -gt 0 ] || die "no skills with a SKILL.md found in $SKILLS_DIR"

is_protected() { case " $PROTECTED " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

if [ "$ACTION" = "list" ]; then
  info "Skills in $SKILLS_DIR (${#skills[@]}):"
  info ""
  for name in "${skills[@]}"; do
    summary="$(awk '
      /^description:[ \t]*>/ { folded = 1; sub(/^description:[ \t]*>[ \t]*/, ""); }
      /^description:[ \t]*[^>|]/ { sub(/^description:[ \t]*/, ""); folded = 0; print; exit }
      folded && NF { gsub(/^[ \t]+/, ""); print; exit }
    ' "$SKILLS_DIR/$name/SKILL.md" | tr -s ' ' | cut -c1-70)"
    printf '  %-22s %s\n' "$name" "${summary:-?}"
  done
  info ""
  info "Canonical target: ${B}$CANONICAL${N}"
  if [ "$MIRROR" -eq 1 ]; then
    info "Symlinked into:"
    for dir in "${MIRRORS[@]}"; do info "  $dir"; done
  fi
  exit 0
fi

# --- preflight ----------------------------------------------------------------
if [ "$ACTION" = "uninstall" ]; then
  info "${B}Uninstalling${N} from $CANONICAL"
else
  info "${B}Installing${N} ${#skills[@]} skill(s) from $SKILLS_DIR"
fi
[ "$DRY_RUN" -eq 1 ] && warn "dry run — nothing will be written"
info ""

run mkdir -p "$CANONICAL"

# --- uninstall ----------------------------------------------------------------
if [ "$ACTION" = "uninstall" ]; then
  for name in "${skills[@]}"; do
    for dir in "${MIRRORS[@]}"; do
      target="$dir/$name"
      [ -L "$target" ] || continue
      run rm -f "$target"
      ok "unlinked $target"
    done
    target="$CANONICAL/$name"
    if [ -d "$target" ] && [ ! -L "$target" ]; then
      run rm -rf "$target"
      ok "removed $target"
    elif [ -L "$target" ]; then
      warn "left $target alone — it is a symlink into the omarchy package"
    fi
  done
  info ""
  info "Done. To also restore the packaged omarchy skill:"
  info "  ln -sfn $OMARCHY_PKG_SKILL $CANONICAL/omarchy"
  exit 0
fi

# --- install ------------------------------------------------------------------
replaced_pkg_symlink=0
installed=0; updated=0; linked=0; skipped=0

for name in "${skills[@]}"; do
  src="$SKILLS_DIR/$name"
  dest="$CANONICAL/$name"

  if is_protected "$name"; then
    warn "skipping $name (owned by the omarchy package)"
    skipped=$((skipped + 1))
    continue
  fi

  # A symlink pointing OUTSIDE $HOME is package/external content (omarchy ships
  # its skills from /usr/share). Replacing it costs only a package update, and we
  # print the restore line — so do it by default. A symlink pointing INSIDE $HOME
  # is the user's own layout: only replace on --force. A real directory that
  # differs is someone's own work: also only replace on --force.
  pkg_symlink=0
  if [ -L "$dest" ]; then
    resolved="$(readlink -f "$dest" 2>/dev/null || true)"
    if [ -n "$resolved" ] && [ "${resolved#"$HOME"/}" = "$resolved" ]; then
      pkg_symlink=1
    fi
  fi

  if [ -e "$dest" ] || [ -L "$dest" ]; then
    # A pre-existing symlink into the package tree means omarchy installed it.
    # Replacing it costs only a package update (and we print the restore line),
    # so do it by default — the flagship skill must not need --force to land.
    # A real directory that differs is someone's own work: only clobber on --force.
    if [ "$pkg_symlink" -eq 1 ]; then
      if [ "$DRY_RUN" -eq 1 ]; then
        warn "$name is an omarchy-package symlink — will be replaced (restore command printed at the end)"
      fi
      replaced_pkg_symlink=1
      info "  ${Y}$name replaces an omarchy-package symlink${N}"
      run rm -rf "$dest"
    else
      if [ -d "$dest" ] || [ -f "$dest/SKILL.md" ]; then
        if diff -rq "$src" "$dest" >/dev/null 2>&1; then
          ok "$name (already up to date)"
          installed=$((installed + 1))
          continue
        fi
        if [ "$FORCE" -ne 1 ]; then
          warn "$name differs and exists — re-run with --force to overwrite"
          skipped=$((skipped + 1))
          continue
        fi
        run rm -rf "$dest"
      elif [ "$FORCE" -ne 1 ]; then
        warn "$name exists but is not a skill dir — re-run with --force"
        skipped=$((skipped + 1))
        continue
      else
        run rm -rf "$dest"
      fi
    fi
  fi

  run cp -rf "$src" "$dest"
  # cp -rf onto an existing symlink-to-dir would write through it; make sure we
  # always end up with a real directory.
  if [ "$DRY_RUN" -eq 0 ] && [ -L "$dest" ]; then
    run rm -rf "$dest"
    run cp -rf "$src" "$dest"
  fi
  ok "$name -> $CANONICAL/$name"
  updated=$((updated + 1))

  # --- mirrors ---
  if [ "$MIRROR" -eq 1 ]; then
    for dir in "${MIRRORS[@]}"; do
      run mkdir -p "$dir"
      link="$dir/$name"
      # Mirror the canonical decision: if we replaced a package symlink in
      # ~/.agents/skills, the mirrors must point at our copy too, or each agent
      # would load a different version of the same skill.
      if [ -L "$link" ]; then
        resolved="$(readlink -f "$link" 2>/dev/null || true)"
        if [ -n "$resolved" ] && [ "${resolved#"$HOME"/}" = "$resolved" ]; then
          info "  ${Y}replacing package symlink $link${N}"
        fi
        run rm -f "$link"
      elif [ -e "$link" ]; then
        if [ "$FORCE" -ne 1 ]; then
          warn "skipping link $link (exists and is not a symlink — use --force)"
          continue
        fi
        run rm -rf "$link"
      fi
      run ln -sfn "$dest" "$link"
      linked=$((linked + 1))
    done
  fi
done

# --- summary ------------------------------------------------------------------
info ""
info "${B}Summary${N}  installed/updated: $updated   linked: $linked   skipped: $skipped"
info "  canonical: $CANONICAL"

if [ "$MIRROR" -eq 1 ]; then
  info "  symlinked: ${#MIRRORS[@]} agent dirs"
  for dir in "${MIRRORS[@]}"; do info "             $dir"; done
fi

if [ "$replaced_pkg_symlink" -eq 1 ]; then
  info ""
  warn "You replaced the packaged ${B}omarchy${N} skill. It will no longer"
  warn "update with 'omarchy update'. To restore the original symlink:"
  info "  rm -rf $CANONICAL/omarchy"
  info "  ln -sfn $OMARCHY_PKG_SKILL $CANONICAL/omarchy"
fi

if [ "$DRY_RUN" -eq 0 ]; then
  info ""
  info "Restart your agent (or start a new session) to pick up the new skills."
fi