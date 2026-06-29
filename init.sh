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

# Ensure gh config directory exists and is writable (gh needs this before auth)
mkdir -p "$HOME/.config/gh"
chmod 700 "$HOME/.config/gh"
# Remove any broken symlinks (bootstrap.sh will recreate them properly)
rm -f "$HOME/.config/gh/config.yml"

## GITHUB AUTH ##

if ! gh auth status &>/dev/null; then
  info "Authenticating with GitHub (browser will open)..."
  gh auth login --git-protocol ssh --web
else
  info "Already authenticated with GitHub, skipping."
fi

# Ensure SSH key permissions are correct (gh creates them too permissive)
info "Fixing SSH key permissions..."
chmod 700 "$HOME/.ssh"
chmod 600 "$HOME/.ssh/id_ed25519" 2>/dev/null || true
chmod 644 "$HOME/.ssh/id_ed25519.pub" 2>/dev/null || true

## ADD SSH KEY TO AGENT ##

info "Adding SSH key to agent (you'll be prompted for passphrase once)..."
# Only add ed25519 key at this stage (symlinks for id_personal/id_work don't exist yet)
ssh-add "$HOME/.ssh/id_ed25519" 2>/dev/null || true

## FIX SSH CONFIG ##

# If ~/.ssh/config includes a file that doesn't exist yet, comment it out temporarily
# (bootstrap.sh will recreate it properly)
if [[ -f "$HOME/.ssh/config" ]] && grep -q "Include.*dotfile-matrix" "$HOME/.ssh/config"; then
  if ! [[ -f "$HOME/.ssh/config.bak" ]]; then
    cp "$HOME/.ssh/config" "$HOME/.ssh/config.bak"
    sed -i '' 's/^Include.*dotfile-matrix.*$/#&/' "$HOME/.ssh/config"
  fi
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
