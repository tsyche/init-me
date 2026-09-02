#!/bin/bash
# Install or update agentrc without moving either live vendor directory.
# Exit 3 means the remote still has the legacy clauderc tree.
set -euo pipefail

remote_url="${1:?usage: install-agentrc.sh REMOTE_URL}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

agentrc_git() {
  git -C "$HOME" --git-dir="$HOME/.agentrc/.git" --work-tree="$HOME" "$@"
}

if [[ -d "$HOME/.agentrc/.git" ]]; then
  agentrc_git fetch --quiet origin
  branch="$(agentrc_git branch --show-current)"
  agentrc_git merge --ff-only --quiet "origin/$branch"
  echo "[agentrc] Updated existing agentrc worktree."
  exit 0
fi

git clone --quiet --no-checkout "$remote_url" "$tmp/repo"
if ! git -C "$tmp/repo" cat-file -e 'HEAD:.agentrc/AGENTS.md' 2>/dev/null; then
  exit 3
fi

mkdir "$tmp/tree"
git -C "$tmp/repo" archive HEAD | tar -x -C "$tmp/tree"

backup_dir="$HOME/agentrc-bootstrap-backup/$(date +%Y%m%d%H%M%S)"
conflicts=0
paths_match() {
  local source_path="$1" target_path="$2"
  if [[ -L "$source_path" || -L "$target_path" ]]; then
    [[ -L "$source_path" && -L "$target_path" ]] \
      && [[ "$(readlink "$source_path")" == "$(readlink "$target_path")" ]]
    return
  fi
  cmp -s "$source_path" "$target_path" || return 1
  if [[ -x "$source_path" ]]; then
    [[ -x "$target_path" ]]
  else
    [[ ! -x "$target_path" ]]
  fi
}

while IFS= read -r -d '' source_path; do
  relative_path="${source_path#"$tmp/tree/"}"
  target_path="$HOME/$relative_path"
  if [[ -e "$target_path" || -L "$target_path" ]]; then
    if ! paths_match "$source_path" "$target_path"; then
      mkdir -p "$backup_dir/$(dirname "$relative_path")"
      mv "$target_path" "$backup_dir/$relative_path"
      mkdir -p "$(dirname "$target_path")"
      cp -a "$source_path" "$target_path"
      conflicts=$((conflicts + 1))
    fi
  else
    mkdir -p "$(dirname "$target_path")"
    cp -a "$source_path" "$target_path"
  fi
done < <(find "$tmp/tree" \( -type f -o -type l \) -print0)

mkdir -p "$HOME/.agentrc"
mv "$tmp/repo/.git" "$HOME/.agentrc/.git"
agentrc_git config core.worktree "$HOME"

if (( conflicts > 0 )); then
  echo "[agentrc] WARNING: $conflicts conflicting tracked file(s) were preserved at $backup_dir" >&2
fi
echo "[agentrc] Installed metadata at $HOME/.agentrc/.git with $HOME as worktree."
