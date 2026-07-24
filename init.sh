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

# Clone/sync $1 (repo name) into $2 (dest) without ever destroying content
# that's already there — same "back it up, never delete" spirit as
# dotfile-matrix's link_safely() for individual dotfiles. Three cases:
#   - dest doesn't exist / is empty: plain clone
#   - dest is already a git checkout: fetch + merge (git's own conflict
#     markers do the reconciling, same as any other merge)
#   - dest exists with real content but ISN'T a git checkout yet (e.g. a
#     ~/.claude that's been in daily use on a box but never linked to the
#     repo): adopt it without clobbering — see _adopt_existing_dir
sync_repo() {
  local repo="$1" dest="$2"

  if [[ -d "$dest/.git" ]]; then
    info "$repo already exists at $dest — fetching and merging..."
    git -C "$dest" fetch --quiet origin
    local branch
    branch="$(git -C "$dest" symbolic-ref --short HEAD)"
    if git -C "$dest" merge --quiet --no-edit "origin/$branch"; then
      info "$repo merged cleanly."
    else
      echo "[init-me] WARNING: $repo has merge conflicts in $dest — resolve them there (conflict markers are in the files) before continuing." >&2
    fi
    return
  fi

  if [[ -e "$dest" ]] && [[ -n "$(ls -A "$dest" 2>/dev/null)" ]]; then
    _adopt_existing_dir "$repo" "$dest"
    return
  fi

  info "Cloning $repo → $dest..."
  gh repo clone "$GITHUB_USER/$repo" "$dest"
}

_adopt_existing_dir() {
  local repo="$1" dest="$2"
  local tmp
  tmp="$(mktemp -d)"
  info "$dest already has content but isn't a git checkout — adopting $repo without overwriting anything..."
  gh repo clone "$GITHUB_USER/$repo" "$tmp" --quiet

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
    echo "[init-me] WARNING: $repo — $staged file(s) at $dest differed from the repo." >&2
    echo "[init-me] Originals saved under $backup_dir — review and merge by hand (your local Claude session can help diff them), then delete that directory once resolved." >&2
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
  msys*|cygwin*|mingw*)
    echo ""
    echo "Windows detected. Native Windows bootstrap is not yet implemented."
    echo "Options:"
    echo "  1. Run this inside WSL2 (Ubuntu) — same as Linux path"
    echo "  2. Watch https://github.com/tsyche/init-me for a future init-windows.ps1"
    echo ""
    exit 1
    ;;
  *)
    die "Unsupported OS: $OSTYPE"
    ;;
esac

## LINUX PREREQUISITES ##

if [[ "$OS" == "linux" ]]; then
  if command -v apt-get &>/dev/null; then
    # zsh: dotfile-matrix's bootstrap.sh installs oh-my-zsh next, which needs
    # zsh to already exist. bubblewrap: Homebrew's own installer recommends
    # it for sandboxed formula builds on Linux. Both are only relevant on a
    # genuinely fresh box — check first rather than assume either is missing.
    missing=()
    for pkg in build-essential curl git procps file zsh bubblewrap; do
      dpkg -s "$pkg" &>/dev/null || missing+=("$pkg")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
      info "Installing apt prerequisites: ${missing[*]}..."
      sudo apt-get update -qq
      sudo apt-get install -y "${missing[@]}"
    else
      info "All apt prerequisites already installed, skipping."
    fi
  else
    die "Non-apt Linux detected. Install build-essential, curl, git, zsh manually then re-run."
  fi
fi

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
  info "Authenticating with GitHub..."
  if [[ "$OS" == "mac" ]] || [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    gh auth login --git-protocol ssh --web
  else
    info "(No display detected — gh will offer a device flow URL to authenticate headlessly)"
    gh auth login --git-protocol ssh
  fi
else
  info "Already authenticated with GitHub, skipping."
fi

# Ensure SSH key permissions are correct (gh creates them too permissive)
info "Fixing SSH key permissions..."
chmod 700 "$HOME/.ssh"
chmod 600 "$HOME/.ssh/id_ed25519" 2>/dev/null || true
chmod 644 "$HOME/.ssh/id_ed25519.pub" 2>/dev/null || true

## ADD SSH KEY TO AGENT ##

# Exit status 2 from `ssh-add -l` specifically means "no agent reachable" (1
# means an agent is up but holds no identities yet — that's fine, don't
# start a redundant one). macOS always has one via launchd; a bare Linux
# server doesn't unless something started one, so check rather than assume.
agent_status=0
ssh-add -l &>/dev/null || agent_status=$?
if [[ "$agent_status" -eq 2 ]]; then
  # This script runs via `bash <(curl ...)` — a new process each time, so it
  # never inherits a prior run's SSH_AUTH_SOCK. Without this, re-running the
  # bootstrap after a failure leaks one orphaned ssh-agent per attempt.
  # Kill any of ours from earlier attempts before starting a single fresh one.
  if pgrep -u "$(id -u)" -x ssh-agent &>/dev/null; then
    info "Found orphaned ssh-agent process(es) from a previous run — killing before starting fresh..."
    pkill -u "$(id -u)" -x ssh-agent || true
  fi
  info "No ssh-agent reachable — starting one..."
  eval "$(ssh-agent -s)" >/dev/null
fi

info "Adding SSH key to agent (you'll be prompted for passphrase once)..."
# Only add ed25519 key at this stage (symlinks for id_personal/id_work don't exist yet)
ssh-add "$HOME/.ssh/id_ed25519" || true

## FIX SSH CONFIG ##

# If ~/.ssh/config includes a file that doesn't exist yet, comment it out temporarily
# (bootstrap.sh will recreate it properly)
if [[ -f "$HOME/.ssh/config" ]] && grep -q "Include.*dotfile-matrix" "$HOME/.ssh/config"; then
  if ! [[ -f "$HOME/.ssh/config.bak" ]]; then
    cp "$HOME/.ssh/config" "$HOME/.ssh/config.bak"
    if [[ "$OS" == "mac" ]]; then
      sed -i '' 's/^Include.*dotfile-matrix.*$/#&/' "$HOME/.ssh/config"
    else
      sed -i 's/^Include.*dotfile-matrix.*$/#&/' "$HOME/.ssh/config"
    fi
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

  sync_repo "$repo" "$dest"
done

## HAND OFF ##

info "All repos cloned. Kicking off setup-all.sh..."
echo ""
exec "$REPOS_DIR/init-me/setup-all.sh"
