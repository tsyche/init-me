#!/bin/bash
# Unified setup for all 4 repos: dotfile-matrix, clauderc, configgy-smalls, scriptorium
# Idempotent — safe to re-run anytime. Clones missing repos, pulls latest, runs setup for each.
#
# Usage:
#   ~/Repos/init-me/setup-all.sh
#
# Supports: macOS, Linux
set -euo pipefail

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
  echo "Logging this run to $LOG_FILE"
fi

GITHUB_USER="tsyche"
REPOS_DIR="$HOME/Repos"
CLAUDERC_DEST="$HOME/.claude"

info()  { echo "[setup-all] $*"; }
warn()  { echo "[setup-all] WARNING: $*" >&2; }
die()   { echo "[setup-all] ERROR: $*" >&2; exit 1; }

## HELPERS ##

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
  git clone "git@github.com:$GITHUB_USER/$repo.git" "$dest" || die "Failed to clone $repo"
}

_adopt_existing_dir() {
  local repo="$1" dest="$2"
  local tmp
  tmp="$(mktemp -d)"
  info "$dest already has content but isn't a git checkout — adopting $repo without overwriting anything..."
  git clone --quiet "git@github.com:$GITHUB_USER/$repo.git" "$tmp" || { warn "Failed to clone $repo for adoption"; rm -rf "$tmp"; return; }

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

# Clone/pull clauderc
sync_repo "clauderc" "$CLAUDERC_DEST"

# Clone/pull configgy-smalls
sync_repo "configgy-smalls" "$REPOS_DIR/configgy-smalls"

# Clone/pull scriptorium
sync_repo "scriptorium" "$REPOS_DIR/scriptorium"

## RUN SETUP FOR EACH REPO ##

info "Running setup for each repo..."

# dotfile-matrix: full bootstrap
info "Step 1: dotfile-matrix bootstrap..."
"$REPOS_DIR/dotfile-matrix/bootstrap.sh" || warn "dotfile-matrix bootstrap had issues"

# configgy-smalls: sync if it has a sync script
if [[ -f "$REPOS_DIR/configgy-smalls/sync.sh" ]]; then
  info "Step 2: configgy-smalls sync..."
  "$REPOS_DIR/configgy-smalls/sync.sh" apply || warn "configgy-smalls sync had issues"
else
  info "Step 2: configgy-smalls (no sync.sh, skipping)"
fi

# scriptorium: symlink ~/Scripts if not already done
if [[ -L "$HOME/Scripts" ]]; then
  info "Step 3: ~/Scripts already symlinked, skipping"
elif [[ -e "$HOME/Scripts" ]]; then
  warn "~/Scripts exists but is not a symlink — skipping to avoid overwriting"
else
  info "Step 3: Symlinking ~/Scripts → $REPOS_DIR/scriptorium/scripts..."
  ln -s "$REPOS_DIR/scriptorium/scripts" "$HOME/Scripts"
fi

# clauderc: no setup needed (it's just configs, auto-loaded from ~/.claude)
info "Step 4: clauderc (no setup needed, already in place)"

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
