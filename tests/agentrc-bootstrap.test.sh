#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_repo() {
  local repo="$1"
  git -C "$repo" init -q
  git -C "$repo" config user.name test
  git -C "$repo" config user.email test@example.invalid
}

legacy="$TEST_ROOT/legacy"
mkdir -p "$legacy"
make_repo "$legacy"
printf 'legacy\n' > "$legacy/CLAUDE.md"
git -C "$legacy" add .
git -C "$legacy" commit -qm legacy

legacy_home="$TEST_ROOT/legacy-home"
mkdir -p "$legacy_home"
set +e
HOME="$legacy_home" "$ROOT/scripts/install-agentrc.sh" "$legacy"
legacy_status=$?
set -e
[[ "$legacy_status" == 3 ]] || fail "legacy tree returned $legacy_status, expected 3"
[[ ! -e "$legacy_home/.agentrc" ]] || fail "legacy tree created .agentrc"

migrated="$TEST_ROOT/migrated"
mkdir -p "$migrated/.agentrc" "$migrated/.claude" "$migrated/.codex"
make_repo "$migrated"
printf '/*\n!/.gitignore\n!/.agentrc/\n!/.claude/\n!/.codex/\n' > "$migrated/.gitignore"
printf 'instructions\n' > "$migrated/.agentrc/AGENTS.md"
printf 'repository version\n' > "$migrated/.claude/tracked"
printf 'tools\n' > "$migrated/.claude/TOOLS.md"
printf 'portable\n' > "$migrated/.codex/AGENTS.md"
ln -s ../.claude/TOOLS.md "$migrated/.codex/TOOLS.md"
git -C "$migrated" add .
git -C "$migrated" commit -qm migrated

legacy_checkout_home="$TEST_ROOT/legacy-checkout-home"
mkdir -p "$legacy_checkout_home/.claude"
make_repo "$legacy_checkout_home/.claude"
printf 'local memory\n' > "$legacy_checkout_home/.claude/MEMORY.md"
git -C "$legacy_checkout_home/.claude" add .
git -C "$legacy_checkout_home/.claude" commit -qm 'local legacy work'
set +e
HOME="$legacy_checkout_home" "$ROOT/scripts/install-agentrc.sh" "$migrated"
legacy_checkout_status=$?
set -e
[[ "$legacy_checkout_status" == 4 ]] \
  || fail "legacy checkout returned $legacy_checkout_status, expected 4"
[[ ! -e "$legacy_checkout_home/.agentrc" ]] \
  || fail "legacy checkout created .agentrc before its metadata was preserved"

wrong_root_home="$TEST_ROOT/wrong-root-home"
mkdir -p "$wrong_root_home"
git clone -q "$migrated" "$wrong_root_home/.claude"
set +e
wrong_root_output="$(HOME="$wrong_root_home" "$ROOT/scripts/install-agentrc.sh" "$migrated" 2>&1)"
wrong_root_status=$?
set -e
[[ "$wrong_root_status" == 6 ]] \
  || fail "wrong-root checkout returned $wrong_root_status, expected 6"
grep -Fq 'one level too deep' <<< "$wrong_root_output" \
  || fail "wrong-root checkout did not explain the detected topology"
[[ ! -e "$wrong_root_home/.agentrc" ]] \
  || fail "wrong-root checkout created the real .agentrc directory"
mkdir -p "$wrong_root_home/wrong-root-backup"
mv "$wrong_root_home/.claude/.git" "$wrong_root_home/wrong-root-backup/clauderc.git"
set +e
HOME="$wrong_root_home" "$ROOT/scripts/install-agentrc.sh" "$migrated" >/dev/null 2>&1
wrong_root_without_git_status=$?
set -e
[[ "$wrong_root_without_git_status" == 6 ]] \
  || fail "wrong-root checkout without .git returned $wrong_root_without_git_status, expected 6"
for wrong_root_path in .agentrc .claude .codex .gitignore README.md; do
  if [[ -e "$wrong_root_home/.claude/$wrong_root_path" \
    || -L "$wrong_root_home/.claude/$wrong_root_path" ]]; then
    mv "$wrong_root_home/.claude/$wrong_root_path" \
      "$wrong_root_home/wrong-root-backup/$wrong_root_path"
  fi
done
HOME="$wrong_root_home" "$ROOT/scripts/install-agentrc.sh" "$migrated"
git -C "$wrong_root_home" --git-dir="$wrong_root_home/.agentrc/.git" \
  --work-tree="$wrong_root_home" diff --quiet \
  || fail "recovered wrong-root worktree differs from HEAD"
git -C "$wrong_root_home" --git-dir="$wrong_root_home/.agentrc/.git" \
  --work-tree="$wrong_root_home" diff --cached --quiet \
  || fail "recovered wrong-root index differs from HEAD"
[[ -d "$wrong_root_home/wrong-root-backup/clauderc.git" ]] \
  || fail "wrong-root recovery did not preserve legacy Git metadata"

migrated_home="$TEST_ROOT/migrated-home"
mkdir -p "$migrated_home/.claude" "$migrated_home/.codex"
printf 'local version\n' > "$migrated_home/.claude/tracked"
printf 'tools\n' > "$migrated_home/.claude/TOOLS.md"
ln -s "$migrated_home/.claude/TOOLS.md" "$migrated_home/.codex/TOOLS.md"
printf 'secret runtime\n' > "$migrated_home/.codex/auth.json"
HOME="$migrated_home" "$ROOT/scripts/install-agentrc.sh" "$migrated"

[[ -d "$migrated_home/.agentrc/.git" ]] || fail "metadata was not installed"
[[ "$(cat "$migrated_home/.claude/tracked")" == 'repository version' ]] || fail "tracked file was not installed"
[[ "$(cat "$migrated_home/.codex/auth.json")" == 'secret runtime' ]] || fail "runtime auth file was overwritten"
[[ "$(readlink "$migrated_home/.codex/TOOLS.md")" == '../.claude/TOOLS.md' ]] || fail "machine-specific symlink was not normalized"
find "$migrated_home/agentrc-bootstrap-backup" -type f -name tracked -exec grep -Fq 'local version' {} \; \
  -print | grep -q . || fail "conflicting tracked file was not backed up"
git -C "$migrated_home" --git-dir="$migrated_home/.agentrc/.git" --work-tree="$migrated_home" diff --quiet \
  || fail "installed tracked tree differs from HEAD"
git -C "$migrated_home" --git-dir="$migrated_home/.agentrc/.git" --work-tree="$migrated_home" diff --cached --quiet \
  || fail "installed index differs from HEAD"

echo "agentrc bootstrap tests passed"
