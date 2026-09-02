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

echo "agentrc bootstrap tests passed"
