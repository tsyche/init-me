#!/bin/bash
# New machine bootstrap — installs Homebrew, authenticates GitHub, clones all
# config repos, then hands off to dotfile-matrix/bootstrap.sh for full setup.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/tsyche/init-me/main/init.sh)
#
# Supports: macOS, Linux
# Windows: run inside WSL or Git Bash first (native Windows support is a future add)
set -euo pipefail

GITHUB_USER="tsyche"
REPOS_DIR="$HOME/Repos"

PRIVATE_REPOS=(
  "init-me"
  "dotfile-matrix"
  "clauderc"
  "configgy-smalls"
  "scriptorium"
)

# clauderc clones directly into ~/.claude, not ~/Repos
CLAUDERC_DEST="$HOME/.claude"

info()  { echo "[init-me] $*"; }
die()   { echo "[init-me] ERROR: $*" >&2; exit 1; }

clone_or_prompt() {
  local repo="$1" dest="$2"
  if [[ -d "$dest/.git" ]]; then
    # Warn if there are uncommitted changes
    local dirty=""
    git -C "$dest" status --porcelain 2>/dev/null | grep -q . && dirty=" (WARNING: has uncommitted changes)"
    read -r -p "[init-me] $repo already exists at $dest$dirty — re-clone? [y/N] " answer
    case "$answer" in
      [yY])
        info "Re-cloning $repo..."
        rm -rf "$dest"
        gh repo clone "$GITHUB_USER/$repo" "$dest"
        ;;
      *)
        info "Skipping $repo."
        ;;
    esac
  else
    info "Cloning $repo → $dest..."
    gh repo clone "$GITHUB_USER/$repo" "$dest"
  fi
}

## OS CHECK ##

case "$OSTYPE" in
  darwin*) OS=mac ;;
  linux*)  OS=linux ;;
  *)
    die "Unsupported OS: $OSTYPE. On Windows, run this inside WSL or Git Bash (native Windows support is a future add)."
    ;;
esac

## HOMEBREW ##

if ! command -v brew &>/dev/null; then
  info "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Add brew to PATH for the rest of this script
  if [[ "$OS" == "mac" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
  else
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  fi
else
  info "Homebrew already installed, skipping."
fi

## GH CLI ##

if ! command -v gh &>/dev/null; then
  info "Installing gh CLI..."
  brew install gh
else
  info "gh already installed, skipping."
fi

## GITHUB AUTH ##

if ! gh auth status &>/dev/null; then
  info "Authenticating with GitHub (browser will open)..."
  gh auth login --git-protocol ssh --web
else
  info "Already authenticated with GitHub, skipping."
fi

## CLONE REPOS ##

mkdir -p "$REPOS_DIR"

for repo in "${PRIVATE_REPOS[@]}"; do
  if [[ "$repo" == "clauderc" ]]; then
    dest="$CLAUDERC_DEST"
  else
    dest="$REPOS_DIR/$repo"
  fi

  clone_or_prompt "$repo" "$dest"
done

## HAND OFF ##

info "All repos cloned. Kicking off setup-all.sh..."
echo ""
exec "$REPOS_DIR/init-me/setup-all.sh"
