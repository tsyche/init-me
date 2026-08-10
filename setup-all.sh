#!/bin/bash
# Unified setup for all 4 repos: dotfile-matrix, clauderc, configgy-smalls, scriptorium
# Idempotent — safe to re-run anytime. Clones missing repos, pulls latest, runs setup for each.
#
# Usage:
#   ~/Repos/init-me/setup-all.sh
#
# Supports: macOS, Linux
set -Eeuo pipefail
# -E (errtrace): without it, the ERR trap below silently skips failures
# inside command substitutions ($(...)) and functions — found live 2026-08-10
# debugging a bootstrap.sh death that produced zero trap output despite the
# trap being in place, because the trap wasn't propagating into subshells.
trap 'echo "[setup-all] ERROR: died at line $LINENO running: $BASH_COMMAND" >&2' ERR

# Capture this run to a timestamped log, always. Guarded so that when this
# runs as part of init.sh's handoff, it inherits init.sh's already-active log
# instead of starting a redundant second one — only sets up its own when run
# standalone (see init.sh for the full rationale).
if [[ -z "${BOOTSTRAP_LOG_ACTIVE:-}" ]]; then
  export BOOTSTRAP_LOG_ACTIVE=1
  LOG_DIR="$HOME/bootstrap-logs"
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/setup-all-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOG_FILE") 2>&1
  # See dotfile-matrix/bootstrap.sh for the full rationale: without this,
  # bash exits without waiting for the tee child, losing whatever it still
  # had buffered — including the error that killed the script.
  trap 'exec 1>&- 2>&-; wait' EXIT
  echo "Logging this run to $LOG_FILE"
fi

GITHUB_USER="tsyche"
REPOS_DIR="$HOME/Repos"
CLAUDERC_DEST="$HOME/.claude"

info()  { echo "[setup-all] $*"; }
warn()  { echo "[setup-all] WARNING: $*" >&2; }
die()   { echo "[setup-all] ERROR: $*" >&2; exit 1; }

## MACHINE TYPE ##

# Inherited from init.sh's handoff when run that way; asks for itself when
# run standalone. See init.sh for the full rationale.
if [[ -z "${MACHINE_TYPE:-}" ]]; then
  echo "What kind of machine is this?"
  echo "  1) Personal (your own hardware)"
  echo "  2) Employer-owned (not your own hardware)"
  echo "  3) Family/other person's machine (not your daily use — setting it up for someone else)"
  read -r -p "Select 1, 2, or 3: " _machine_choice
  case "$_machine_choice" in
    2) export MACHINE_TYPE="employer" ;;
    3) export MACHINE_TYPE="family" ;;
    *) export MACHINE_TYPE="personal" ;;
  esac
fi
if [[ "$MACHINE_TYPE" == "employer" ]]; then
  info "Employer machine — cloning over HTTPS with a PAT instead of SSH keys. The PAT itself never touches disk, but note the cache below is a background daemon with a 4-hour timeout, not scoped to this script run — it's purged explicitly once the last clone/pull below finishes, not left to expire on its own."
  # Empty value resets git's cumulative helper list, dropping macOS's
  # system-level osxkeychain — see init.sh for the full rationale.
  git config --global --replace-all credential.helper ""
  git config --global --add credential.helper 'cache --timeout=14400'
elif [[ "$MACHINE_TYPE" == "family" ]]; then
  info "Family/other-person machine — cloning over HTTPS with a PAT. Same purge-after-use handling as the employer-machine path."
  git config --global --replace-all credential.helper ""
  git config --global --add credential.helper 'cache --timeout=14400'
fi

## HELPERS ##

# Runs a sub-script and reports what actually happened to it. Replaces the
# old `script.sh || warn "X had issues"` pattern, which printed the identical
# message whether the script failed at runtime, wasn't executable, or did not
# exist at all. That ambiguity cost a long debugging session on 2026-08-10:
# a missing bootstrap.sh (exit 127, never ran) was reported as "bootstrap had
# issues", which reads as "it ran and something went wrong" and sent the
# investigation entirely the wrong way. Existence and executability are now
# checked up front, and the real exit code is always reported.
run_step() {
  local label="$1" path="$2"
  shift 2

  if [[ ! -e "$path" ]]; then
    warn "$label — DID NOT RUN: $path does not exist"
    return
  fi
  if [[ ! -x "$path" ]]; then
    warn "$label — DID NOT RUN: $path exists but is not executable (chmod +x)"
    return
  fi

  local rc=0
  "$path" "$@" || rc=$?
  case "$rc" in
    0)   ;;
    126) warn "$label — FAILED (rc=126): found but could not be executed" ;;
    127) warn "$label — FAILED (rc=127): a command inside it was not found" ;;
    *)   warn "$label — FAILED (rc=$rc). Where it stopped: tail -5 ~/bootstrap-steps.log; why: cat ~/bootstrap-error.log" ;;
  esac
}

# Builds the clone URL for $1 (repo name) — SSH for personal machines, HTTPS
# with the username embedded for employer-owned and family/other-person
# ones. See init.sh's _clone_url for the full rationale.
_clone_url() {
  if [[ "$MACHINE_TYPE" == "employer" || "$MACHINE_TYPE" == "family" ]]; then
    echo "https://$GITHUB_USER@github.com/$GITHUB_USER/$1.git"
  else
    echo "git@github.com:$GITHUB_USER/$1.git"
  fi
}

# Same safe-sync behavior as init.sh's sync_repo() — never overwrite content
# that's already at $dest. See init.sh for the full rationale.
sync_repo() {
  local repo="$1" dest="$2"

  if [[ -d "$dest/.git" ]]; then
    info "Pulling $repo → $dest..."
    git -C "$dest" fetch --quiet origin || { warn "Fetch failed for $repo"; return; }
    local branch
    branch="$(git -C "$dest" symbolic-ref --short HEAD)"
    git -C "$dest" merge --quiet --no-edit "origin/$branch" \
      || warn "$repo has merge conflicts in $dest — resolve them there before continuing"
    return
  fi

  if [[ -e "$dest" ]] && [[ -n "$(ls -A "$dest" 2>/dev/null)" ]]; then
    _adopt_existing_dir "$repo" "$dest"
    return
  fi

  info "Cloning $repo → $dest..."
  # Plain git clone, not `gh repo clone` — see init.sh's sync_repo for why
  # (avoids an unnecessary GraphQL API dependency for a step that doesn't
  # need it).
  git clone "$(_clone_url "$repo")" "$dest" || die "Failed to clone $repo"
}

_adopt_existing_dir() {
  local repo="$1" dest="$2"
  local tmp
  tmp="$(mktemp -d)"
  info "$dest already has content but isn't a git checkout — adopting $repo without overwriting anything..."
  git clone --quiet "$(_clone_url "$repo")" "$tmp" || { warn "Failed to clone $repo for adoption"; rm -rf "$tmp"; return; }

  local backup_dir="$dest/.merge-pending/$(date +%Y%m%d%H%M%S)"
  local staged=0

  while IFS= read -r relpath; do
    local src="$tmp/$relpath" tgt="$dest/$relpath"
    if [[ -e "$tgt" ]]; then
      if ! diff -q "$src" "$tgt" &>/dev/null; then
        mkdir -p "$(dirname "$backup_dir/$relpath")"
        mv "$tgt" "$backup_dir/$relpath"
        mkdir -p "$(dirname "$tgt")"
        cp "$src" "$tgt"
        staged=$((staged + 1))
      fi
    else
      mkdir -p "$(dirname "$tgt")"
      cp "$src" "$tgt"
    fi
  done < <(git -C "$tmp" ls-tree -r --name-only HEAD)

  rm -rf "$dest/.git"
  cp -a "$tmp/.git" "$dest/.git"
  rm -rf "$tmp"

  # Stage (never auto-commit) anything local-only that the adopted .gitignore
  # doesn't exclude — new skills/memory edits that never got pushed. Leaving
  # them untracked would "preserve" them on disk but never fold them into the
  # repo, which defeats the point of adopting in the first place.
  git -C "$dest" add -A -- ':!.merge-pending'
  local new_local
  new_local="$(git -C "$dest" diff --cached --name-only --diff-filter=A | wc -l | tr -d ' ')"

  if (( staged > 0 )); then
    warn "$repo — $staged file(s) at $dest differed from the repo."
    warn "Originals saved under $backup_dir — review and merge by hand (your local Claude session can help diff them), then delete that directory once resolved."
  else
    info "$repo adopted cleanly, no conflicting files."
  fi
  if (( new_local > 0 )); then
    info "$repo — $new_local local-only file(s) staged (not committed) into the repo: git -C \"$dest\" diff --cached to review, commit when ready."
  fi
}

## OS CHECK ##

case "$OSTYPE" in
  darwin*) OS=mac ;;
  linux*)  OS=linux ;;
  *)
    die "Unsupported OS: $OSTYPE"
    ;;
esac

## BOOTSTRAP REPOS ##

mkdir -p "$REPOS_DIR"

# Clone/pull dotfile-matrix
sync_repo "dotfile-matrix" "$REPOS_DIR/dotfile-matrix"

# Clone/pull clauderc — skipped on employer machines, since Claude Code
# itself (claude-code@latest) is already in bootstrap.sh's EMPLOYER_EXCLUDES
# and never gets installed there; nothing to serve its config repo either.
# Family/other-person machines get the same "light" skills/scripts-only
# treatment as init.sh — see there for the full rationale.
if [[ "$MACHINE_TYPE" == "employer" ]]; then
  info "Employer machine — skipping clauderc (Claude Code isn't installed there either)."
elif [[ "$MACHINE_TYPE" == "family" ]]; then
  read -r -p "Install the custom Claude skills/scripts on this machine? [y/N] " _want_clauderc_light
  if [[ "$_want_clauderc_light" =~ ^[Yy]$ ]]; then
    info "Installing skills/scripts only (not a full clauderc clone)..."
    _tmp_clauderc="$(mktemp -d)"
    git clone --quiet --depth=1 "$(_clone_url "clauderc")" "$_tmp_clauderc"
    mkdir -p "$CLAUDERC_DEST"
    cp -a "$_tmp_clauderc/skills" "$CLAUDERC_DEST/" 2>/dev/null || true
    cp -a "$_tmp_clauderc/scripts" "$CLAUDERC_DEST/" 2>/dev/null || true
    rm -rf "$_tmp_clauderc"
    info "skills/scripts installed to $CLAUDERC_DEST."
  fi
else
  sync_repo "clauderc" "$CLAUDERC_DEST"
fi

# Clone/pull configgy-smalls and scriptorium — skipped entirely on
# family/other-person machines, same reasoning as init.sh: these are
# exactly the "specific to you" content that machine type shouldn't carry.
if [[ "$MACHINE_TYPE" == "family" ]]; then
  info "Family/other-person machine — skipping configgy-smalls and scriptorium (not applicable here)."
else
  sync_repo "configgy-smalls" "$REPOS_DIR/configgy-smalls"
  sync_repo "scriptorium" "$REPOS_DIR/scriptorium"
fi

# Purge the cached PAT now — this is the last git operation over HTTPS that
# needs it. `credential.helper cache` runs a background daemon that holds
# the credential for the full --timeout window (4 hours) regardless of
# whether this script has exited, and is set with --global so it'd also
# cache the next password any git command on this machine prompts for.
# Neither of those is acceptable to leave lingering on hardware you don't
# own, so purge both the live credential and the standing config
# immediately rather than letting the timeout do it eventually.
if [[ "$MACHINE_TYPE" == "employer" || "$MACHINE_TYPE" == "family" ]]; then
  git credential-cache exit 2>/dev/null || true
  git config --global --unset-all credential.helper 2>/dev/null || true
  # Belt-and-braces on macOS: any run from before the osxkeychain override
  # above already persisted the PAT into the login Keychain, and unsetting
  # the helper does not remove what is already stored there. Deleting by
  # service is safe — this only targets the github.com internet-password
  # entry, and a machine of this type has no business keeping one.
  if [[ "$OSTYPE" == darwin* ]]; then
    security delete-internet-password -s github.com &>/dev/null || true
  fi
  info "Purged the cached GitHub PAT, reset credential.helper, and cleared any Keychain entry — nothing left lingering."
fi

## RUN SETUP FOR EACH REPO ##

info "Running setup for each repo..."

# dotfile-matrix: full bootstrap
info "Step 1: dotfile-matrix bootstrap..."
run_step "dotfile-matrix bootstrap" "$REPOS_DIR/dotfile-matrix/bootstrap.sh"

# configgy-smalls: sync if it has a sync script — never cloned at all on
# family/other-person machines, so this check naturally no-ops there too,
# but an explicit message is clearer than the generic "no sync.sh" one.
if [[ "$MACHINE_TYPE" == "family" ]]; then
  info "Step 2: configgy-smalls (skipped, family/other-person machine)"
elif [[ -f "$REPOS_DIR/configgy-smalls/sync.sh" ]]; then
  info "Step 2: configgy-smalls sync..."
  run_step "configgy-smalls sync" "$REPOS_DIR/configgy-smalls/sync.sh" apply
else
  info "Step 2: configgy-smalls (no sync.sh, skipping)"
fi

# scriptorium: symlink ~/Scripts if not already done. Explicitly skipped on
# family/other-person machines — without this check the `ln -s` below would
# happily create a dangling symlink pointing at a scriptorium checkout that
# deliberately doesn't exist there (found while auditing this machine type).
if [[ "$MACHINE_TYPE" == "family" ]]; then
  info "Step 3: ~/Scripts symlink (skipped, family/other-person machine)"
elif [[ -L "$HOME/Scripts" ]]; then
  info "Step 3: ~/Scripts already symlinked, skipping"
elif [[ -e "$HOME/Scripts" ]]; then
  warn "~/Scripts exists but is not a symlink — skipping to avoid overwriting"
else
  info "Step 3: Symlinking ~/Scripts → $REPOS_DIR/scriptorium/scripts..."
  ln -s "$REPOS_DIR/scriptorium/scripts" "$HOME/Scripts"
fi

# ~/.agents/skills: symlink to clauderc's skills dir if present. Several
# non-Claude agent tools (VS Code Copilot, others following the
# agentskills.io open SKILL.md format) look in ~/.agents/skills as one of
# their discovery paths — this makes the same skills visible there for free
# instead of duplicating them. No-op if clauderc wasn't installed (employer
# machines, or family machines that declined the light install).
if [[ -L "$HOME/.agents/skills" ]]; then
  info "Step 4: ~/.agents/skills already symlinked, skipping"
elif [[ -e "$HOME/.agents/skills" ]]; then
  warn "~/.agents/skills exists but is not a symlink — skipping to avoid overwriting"
elif [[ -d "$CLAUDERC_DEST/skills" ]]; then
  info "Step 4: Symlinking ~/.agents/skills → $CLAUDERC_DEST/skills..."
  mkdir -p "$HOME/.agents"
  ln -s "$CLAUDERC_DEST/skills" "$HOME/.agents/skills"
else
  info "Step 4: ~/.agents/skills (no $CLAUDERC_DEST/skills, skipping)"
fi

# clauderc: no setup needed (it's just configs, auto-loaded from ~/.claude)
if [[ "$MACHINE_TYPE" == "employer" ]]; then
  info "Step 5: clauderc (skipped, employer machine)"
elif [[ "$MACHINE_TYPE" == "family" ]]; then
  info "Step 5: clauderc (light install only if you opted in above, no further setup needed)"
else
  info "Step 5: clauderc (no setup needed, already in place)"
fi

## DONE ##

pending=()
for d in "$REPOS_DIR/dotfile-matrix" "$CLAUDERC_DEST" "$REPOS_DIR/configgy-smalls" "$REPOS_DIR/scriptorium"; do
  if [[ -d "$d/.merge-pending" ]] && [[ -n "$(ls -A "$d/.merge-pending" 2>/dev/null)" ]]; then
    pending+=("$d/.merge-pending")
  fi
done

info "Setup complete!"
info ""
if (( ${#pending[@]} > 0 )); then
  warn "Unresolved merge conflicts from adopting existing content:"
  for p in "${pending[@]}"; do
    warn "  $p"
  done
  info "Ask your local Claude session to diff these against the current files and merge anything worth keeping, then delete each .merge-pending directory."
  info ""
fi
info "Next steps:"
info "  1. Restart your shell: zrestart"
info "  2. Configure machine-specific settings: edit ~/.zshrc.local and ~/.gitconfig.local"
info "  3. Run /system-cleanup anytime to audit disk usage"
