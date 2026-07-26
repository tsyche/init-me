#!/bin/bash
# New machine bootstrap — installs Homebrew, authenticates GitHub, clones all
# config repos, then hands off to dotfile-matrix/bootstrap.sh for full setup.
#
# Usage (GitHub first, falls back to the GitLab mirror if that fetch fails):
#   bash <(curl -fsSL https://raw.githubusercontent.com/tsyche/init-me/main/init.sh || curl -fsSL https://gitlab.com/tsyche/init-me/-/raw/main/init.sh)
#
# Supports: macOS, Linux
# Windows: run inside WSL or Git Bash first (native Windows support is a future add)
set -euo pipefail

## MACHINE TYPE ##

# Determines the credential mechanism used below (SSH keys tied to your own
# GitHub identities vs. a short-lived PAT over HTTPS) — asked first, before
# anything else happens, since it changes what the rest of this script even
# does. Exported so setup-all.sh/bootstrap.sh inherit the answer instead of
# asking again (same pattern as BOOTSTRAP_LOG_ACTIVE below) — each still
# asks for itself if run standalone, when this isn't already set.
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
echo "[init-me] Machine type: $MACHINE_TYPE"

# Capture this run to a timestamped log, always — no more manually
# remembering `| tee` after losing scrollback mid-debug. Guarded by
# BOOTSTRAP_LOG_ACTIVE so that when this script hands off to setup-all.sh
# (which hands off to bootstrap.sh), each only sets up logging if it's the
# actual entrypoint — otherwise they just inherit the already-redirected
# output, avoiding nested/duplicate log files.
if [[ -z "${BOOTSTRAP_LOG_ACTIVE:-}" ]]; then
  export BOOTSTRAP_LOG_ACTIVE=1
  LOG_DIR="$HOME/bootstrap-logs"
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/init-me-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "Logging this run to $LOG_FILE"
fi

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

# Builds the clone URL for $1 (repo name) — SSH for personal machines
# (existing behavior, tied to your own GitHub identity), HTTPS with the
# username embedded for employer-owned AND family/other-person machines, so
# git only prompts for the PAT itself, not username too. The
# credential.helper cache set up below keeps that PAT in memory only for the
# rest of this run — never written to disk. Family machines use this same
# mechanism for the initial clone regardless of whether they later opt into
# gh/glab CLI for the actual user's own accounts (that's a separate,
# additional step below, not how dotfile-matrix itself gets here).
_clone_url() {
  if [[ "$MACHINE_TYPE" == "employer" || "$MACHINE_TYPE" == "family" ]]; then
    echo "https://$GITHUB_USER@github.com/$GITHUB_USER/$1.git"
  else
    echo "git@github.com:$GITHUB_USER/$1.git"
  fi
}

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
  # Plain git clone, not `gh repo clone` — the latter does a GraphQL lookup
  # to resolve the repo before cloning, an extra GitHub API dependency this
  # doesn't need since the URL is already known. Found live: repeated heavy
  # gh usage exhausted a GraphQL rate limit and blocked cloning even though
  # a working SSH key already existed.
  git clone "$(_clone_url "$repo")" "$dest"
}

_adopt_existing_dir() {
  local repo="$1" dest="$2"
  local tmp
  tmp="$(mktemp -d)"
  info "$dest already has content but isn't a git checkout — adopting $repo without overwriting anything..."
  git clone --quiet "$(_clone_url "$repo")" "$tmp"

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

# Check the known install path directly, not `command -v brew` — that
# depends on $PATH already including Homebrew's bin dir, which a brand-new
# `bash <(curl ...)` process won't have unless the *parent* shell session
# happened to start after Homebrew's PATH lines were already added. Found
# live: re-running this on a machine with Homebrew genuinely already
# installed, from a shell session that predated it, triggered a full
# (wasteful, alarming-looking) reinstall every time.
if [[ "$OS" == "mac" ]]; then
  if [[ -x /opt/homebrew/bin/brew ]]; then
    BREW_BIN=/opt/homebrew/bin/brew
  elif [[ -x /usr/local/bin/brew ]]; then
    BREW_BIN=/usr/local/bin/brew
  else
    BREW_BIN=""
  fi
  SHELLENV_RC="$HOME/.zprofile"
else
  BREW_BIN=/home/linuxbrew/.linuxbrew/bin/brew
  [[ -x "$BREW_BIN" ]] || BREW_BIN=""
  SHELLENV_RC="$HOME/.bashrc"
fi

if [[ -z "$BREW_BIN" ]]; then
  info "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if [[ "$OS" == "mac" ]]; then
    [[ -x /opt/homebrew/bin/brew ]] && BREW_BIN=/opt/homebrew/bin/brew || BREW_BIN=/usr/local/bin/brew
  else
    BREW_BIN=/home/linuxbrew/.linuxbrew/bin/brew
  fi
else
  info "Homebrew already installed, skipping."
fi

# Always runs, install or not — command -v brew (see above) isn't reliable
# for detecting this process's own $PATH state, so always fixing it here is
# the only way to guarantee later steps (gh, etc.) can actually find brew
# tools within this same run, regardless of which branch just fired.
eval "$("$BREW_BIN" shellenv)"
# Persisted for real too, not just this process — any NEW shell opened
# before the tracked zshrc gets symlinked (much later in this pipeline) has
# no idea brew/gh exist otherwise.
SHELLENV_LINE="eval \"\$($BREW_BIN shellenv)\""
grep -qF "$SHELLENV_LINE" "$SHELLENV_RC" 2>/dev/null || echo "$SHELLENV_LINE" >> "$SHELLENV_RC"

## GH CLI / SSH KEYS (personal machines) — PAT over HTTPS (employer-owned) ##

if [[ "$MACHINE_TYPE" == "personal" ]]; then

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

# A stale/invalid token from an earlier partial run can leave gh permanently
# stuck — a known gh CLI bug (github.com/cli/cli/issues/8441): its internal
# config-migration step verifies the existing token first, and if that check
# fails, gh "cowardly refuses" to proceed at all, blocking every subsequent
# gh command including a fresh login. Found live, required manual
# `rm -rf ~/.config/gh` to recover — detect and self-heal instead.
if ! gh auth status &>/tmp/gh-auth-status.err; then
  if grep -q "cowardly refusing to continue" /tmp/gh-auth-status.err; then
    info "gh's local config is stuck on a broken stored token — resetting it..."
    rm -rf "$HOME/.config/gh"
    mkdir -p "$HOME/.config/gh"
    chmod 700 "$HOME/.config/gh"
  fi
fi
rm -f /tmp/gh-auth-status.err

if ! gh auth status &>/dev/null; then
  # Both paths below generate a time-limited code/session the instant they
  # run — gh gives up with "context deadline exceeded" if nobody completes
  # it in time. Pause here so THAT clock only starts once you're actually
  # about to sit and finish it, instead of ticking away while the earlier
  # apt/Homebrew steps run or if you step away right as this section starts.
  read -r -p "About to authenticate with GitHub — this starts a time-limited code, so make sure you're ready to complete it right away. Press Enter when ready... "
  info "Authenticating with GitHub..."
  # admin:public_key is needed below for `gh ssh-key add` — the device-flow
  # login (headless Linux path) doesn't grant it by default, and without it
  # the key-upload step 404s after already having generated a local key.
  if [[ "$OS" == "mac" ]] || [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    gh auth login --git-protocol ssh --web --scopes "admin:public_key"
  else
    info "(No display detected — gh will offer a device flow URL to authenticate headlessly)"
    gh auth login --git-protocol ssh --scopes "admin:public_key"
  fi
else
  info "Already authenticated with GitHub, skipping."
fi

# gh's SSH-key setup prompts don't reliably fire during headless device-flow
# auth (found live: auth succeeded but no key existed afterward) — don't
# assume gh generated one, generate + register it ourselves if it didn't.
mkdir -p "$HOME/.ssh"
# Named id_<hostname>_<date> instead of the generic OpenSSH default
# id_ed25519, both locally and as the title GitHub shows for it — same
# spirit as dotfile-matrix's id_personal/id_work, so this key is
# identifiable at a glance in `~/.ssh/` or GitHub's SSH keys list instead of
# being one of several machines' identically-named "id_ed25519 (2026-07-26)"
# entries. Existence check is a GLOB on id_<hostname>_*, not the exact
# filename — a plain filename match would break on any re-run after today,
# since tomorrow's exact name wouldn't match yesterday's dated file, and
# this script would think no key exists yet and generate a second one.
#
# Pure-bash glob (nullglob), not `ls | grep | head` — found live: when the
# glob matches nothing (the normal case, no dated key yet), `ls` fails and
# `grep -v` on the resulting empty input ALSO returns non-zero ("no lines
# selected"); pipefail then propagates that through the whole assignment,
# and set -e kills the entire script right there with zero error output.
_bootstrap_key_host="$(hostname -s 2>/dev/null || hostname)"
shopt -s nullglob
_bootstrap_key_candidates=("$HOME/.ssh/id_${_bootstrap_key_host}_"[0-9]*)
shopt -u nullglob
_existing_bootstrap_key=""
for _candidate in "${_bootstrap_key_candidates[@]}"; do
  [[ "$_candidate" == *.pub ]] && continue
  _existing_bootstrap_key="$_candidate"
  break
done
if [[ -n "$_existing_bootstrap_key" ]]; then
  BOOTSTRAP_SSH_KEY="$_existing_bootstrap_key"
else
  info "No SSH key present after GitHub auth — generating one (passphrase optional, prompted below)..."
  key_name="id_${_bootstrap_key_host}_$(date +%Y%m%d)"
  BOOTSTRAP_SSH_KEY="$HOME/.ssh/$key_name"
  ssh-keygen -t ed25519 -f "$BOOTSTRAP_SSH_KEY" -C "$(whoami)@${_bootstrap_key_host}"
  key_title="$key_name"
  if ! gh ssh-key add "$BOOTSTRAP_SSH_KEY.pub" --title "$key_title" 2>/tmp/gh-ssh-key-add.err; then
    # A token from a prior run (before this scope was requested at login)
    # won't have admin:public_key — refresh it in place rather than require
    # a full re-auth, then retry the same upload once.
    if grep -q "admin:public_key" /tmp/gh-ssh-key-add.err; then
      info "Existing GitHub token lacks admin:public_key — refreshing scope..."
      # Same time-limited-code risk as the initial login above — this can
      # fire unexpectedly (only triggers if the earlier token was already
      # stale), so it's easy to not be watching when it happens.
      read -r -p "This refresh also needs a fresh device code — press Enter when ready to complete it right away... "
      gh auth refresh -h github.com -s admin:public_key
      gh ssh-key add "$BOOTSTRAP_SSH_KEY.pub" --title "$key_title"
    else
      cat /tmp/gh-ssh-key-add.err >&2
      exit 1
    fi
  fi
  rm -f /tmp/gh-ssh-key-add.err
fi

# github.com isn't in known_hosts on a fresh box, so the first `git clone`
# over SSH fails host-key verification before it ever gets to auth — add it
# up front rather than let that be the first-run surprise.
touch "$HOME/.ssh/known_hosts"
grep -q "^github.com " "$HOME/.ssh/known_hosts" 2>/dev/null || ssh-keyscan -t ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null

# Ensure SSH key permissions are correct (gh creates them too permissive)
info "Fixing SSH key permissions..."
chmod 700 "$HOME/.ssh"
chmod 600 "$BOOTSTRAP_SSH_KEY" 2>/dev/null || true
chmod 644 "$BOOTSTRAP_SSH_KEY.pub" 2>/dev/null || true

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
# Only this bootstrap-time key at this stage (id_personal/id_work don't exist yet)
ssh-add "$BOOTSTRAP_SSH_KEY" || true

elif [[ "$MACHINE_TYPE" == "employer" ]]; then
  # Employer-owned: no gh CLI, no SSH keys tied to your own GitHub
  # identities — none of that belongs on hardware you don't own. Cloning
  # below goes over HTTPS instead, authenticated with a Personal Access
  # Token you create yourself (read-only, scoped to just these repos). git's
  # own credential prompt handles entering it — `cache` here means it's held
  # in memory only for this run and auto-expires; never written to disk, and
  # never handled by this script directly.
  info "Employer machine — using a GitHub Personal Access Token over HTTPS instead of gh CLI/SSH keys."
  info "You'll be prompted for it once (as the password); it's cached in memory for this run only."
  git config --global credential.helper 'cache --timeout=14400'
  # Same reasoning as the gh device-code pause above — the clone right after
  # this triggers the actual username/password prompt, so make sure the PAT
  # is in hand *before* that happens rather than fumbling for it mid-prompt
  # (found live: a username/PAT typo here just looks like a plain auth
  # failure, easy to misdiagnose as something being broken).
  read -r -p "About to clone using your GitHub username + Personal Access Token (as the password) — have both ready. Press Enter when ready... "
else
  # Family/other person's machine: the initial clone below uses the same
  # PAT-over-HTTPS mechanism as employer machines (you're the one running
  # this, using your own PAT) — completely separate from whether the person
  # actually using this machine wants gh/glab CLI set up for THEIR OWN
  # accounts, which is what's actually asked here. Declining either prompt
  # below only skips installing/logging into that CLI — it does NOT skip
  # dotfile-matrix's own id_local key generation later, which happens
  # unconditionally and is saved to disk regardless of what's answered here,
  # ready to be added to any account by hand whenever it's wanted.
  info "Family/other-person machine — cloning with your own PAT over HTTPS (same as employer machines)."
  git config --global credential.helper 'cache --timeout=14400'
  read -r -p "About to clone using your GitHub username + Personal Access Token (as the password) — have both ready. Press Enter when ready... "

  read -r -p "Set up gh (GitHub CLI) on this machine, for its own GitHub account? [y/N] " _want_gh
  if [[ "$_want_gh" =~ ^[Yy]$ ]]; then
    if ! command -v gh &>/dev/null; then
      info "Installing gh CLI..."
      brew install gh
    fi
    # --web here, not the headless device-flow fallback personal machines
    # need — this is someone sitting at the machine, and gh's own prompts
    # (including an optional SSH key setup) work fine interactively. Not
    # duplicating personal's manual key-generation safety net since nothing
    # here depends on it succeeding the way the initial clone did.
    gh auth login --git-protocol ssh --web || info "gh auth login didn't complete — this machine's owner can retry it later with: gh auth login"
  fi

  read -r -p "Set up glab (GitLab CLI) on this machine, for its own GitLab account? [y/N] " _want_glab
  if [[ "$_want_glab" =~ ^[Yy]$ ]]; then
    if ! command -v glab &>/dev/null; then
      info "Installing glab CLI..."
      brew install glab
    fi
    glab auth login --web --git-protocol ssh || info "glab auth login didn't complete — this machine's owner can retry it later with: glab auth login"
  fi
fi

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
    # Claude Code itself (claude-code@latest) is already in bootstrap.sh's
    # EMPLOYER_EXCLUDES, so it's never installed on an employer machine —
    # cloning its config repo there would have nothing to serve. Keeps PAT
    # scoping simpler too: one less repo to grant it access to.
    if [[ "$MACHINE_TYPE" == "employer" ]]; then
      info "Employer machine — skipping clauderc (Claude Code isn't installed there either)."
      continue
    elif [[ "$MACHINE_TYPE" == "family" ]]; then
      # "Light" install, not a full clauderc clone — copies just skills/ and
      # scripts/ out of a throwaway temp clone, then discards the temp
      # clone's git history entirely. ~/.claude on this machine is NOT a git
      # checkout of clauderc: no per-project memory, no plans, nothing of
      # yours ends up here, and nothing this machine's owner does in Claude
      # Code can accidentally get pushed back to your repo. Updating later
      # means re-running the copy, not `git pull` — see scriptorium's
      # refresh script.
      read -r -p "Install the custom Claude skills/scripts on this machine? [y/N] " _want_clauderc_light
      if [[ "$_want_clauderc_light" =~ ^[Yy]$ ]]; then
        info "Installing skills/scripts only (not a full clauderc clone)..."
        _tmp_clauderc="$(mktemp -d)"
        git clone --quiet --depth=1 "$(_clone_url "$repo")" "$_tmp_clauderc"
        mkdir -p "$CLAUDERC_DEST"
        cp -a "$_tmp_clauderc/skills" "$CLAUDERC_DEST/" 2>/dev/null || true
        cp -a "$_tmp_clauderc/scripts" "$CLAUDERC_DEST/" 2>/dev/null || true
        rm -rf "$_tmp_clauderc"
        info "skills/scripts installed to $CLAUDERC_DEST."
      fi
      continue
    fi
    dest="$CLAUDERC_DEST"
  else
    # configgy-smalls (your GUI app prefs) and scriptorium (your personal
    # scripts) are exactly the "specific to you" content a family/other-
    # person machine shouldn't carry — dotfile-matrix (the actual tools) is
    # the only private repo this machine type gets, plus optionally
    # clauderc-light above.
    if [[ "$MACHINE_TYPE" == "family" ]] && { [[ "$repo" == "configgy-smalls" ]] || [[ "$repo" == "scriptorium" ]]; }; then
      info "Family/other-person machine — skipping $repo (not applicable here)."
      continue
    fi
    dest="$REPOS_DIR/$repo"
  fi

  sync_repo "$repo" "$dest"
done

## HAND OFF ##

info "All repos cloned. Kicking off setup-all.sh..."
echo ""
exec "$REPOS_DIR/init-me/setup-all.sh"
