#!/bin/bash
# Unified setup for all 4 repos: dotfile-matrix, clauderc, configgy-smalls, scriptorium
# Idempotent — safe to re-run anytime. Clones missing repos, pulls latest, runs setup for each.
#
# Usage:
#   ~/Repos/init-me/setup-all.sh
#
# Supports: macOS, Linux
set -euo pipefail

GITHUB_USER="tsyche"
REPOS_DIR="$HOME/Repos"
CLAUDERC_DEST="$HOME/.claude"

info()  { echo "[setup-all] $*"; }
warn()  { echo "[setup-all] WARNING: $*" >&2; }
die()   { echo "[setup-all] ERROR: $*" >&2; exit 1; }

## HELPERS ##

clone_or_pull() {
  local repo="$1" dest="$2"

  if [[ -d "$dest/.git" ]]; then
    info "Pulling $repo → $dest..."
    git -C "$dest" pull --quiet || warn "Pull failed for $repo; may have local changes"
  else
    info "Cloning $repo → $dest..."
    gh repo clone "$GITHUB_USER/$repo" "$dest" || die "Failed to clone $repo"
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
clone_or_pull "dotfile-matrix" "$REPOS_DIR/dotfile-matrix"

# Clone/pull clauderc
clone_or_pull "clauderc" "$CLAUDERC_DEST"

# Clone/pull configgy-smalls
clone_or_pull "configgy-smalls" "$REPOS_DIR/configgy-smalls"

# Clone/pull scriptorium
clone_or_pull "scriptorium" "$REPOS_DIR/scriptorium"

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

info "Setup complete!"
info ""
info "Next steps:"
info "  1. Restart your shell: zrestart"
info "  2. Configure machine-specific settings: edit ~/.zshrc.local and ~/.gitconfig.local"
info "  3. Run /system-cleanup anytime to audit disk usage"
