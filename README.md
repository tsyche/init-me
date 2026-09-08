# init-me

## TL;DR

Bootstrap a blank macOS or Linux machine into the tracked personal setup.
Personal installs safely adopt agentrc's `$HOME` worktree; reduced-trust
machine types receive narrower configuration.

## Usage

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tsyche/init-me/main/init.sh || curl -fsSL https://gitlab.com/tsyche/init-me/-/raw/main/init.sh)
```

Tries GitHub first, falls back to the GitLab mirror if that fetch fails —
same script either way, kept in sync manually for now.

You'll be prompted for:
1. What kind of machine this is — personal, employer-owned, or a
   family/other person's machine you're setting up for someone else, not
   your own daily use (changes the credential mechanism and what gets
   installed below, see `init.sh` for details)
2. Homebrew install (sudo password, macOS only first time)
3. Personal machines: `gh auth login` (opens browser — log in and approve).
   Employer-owned and family/other-person machines: a GitHub Personal Access
   Token instead (no gh CLI, no SSH keys tied to your own GitHub identities)
   for the initial clone — family machines then get an optional follow-up
   prompt to set up `gh`/`glab` for real, logged into the machine's own
   owner's accounts, not yours

Everything else is automated.

### Creating the PAT (employer-owned / family machines)

Generate a **fine-grained** token immediately before running, at GitHub →
Settings → Developer settings → Personal access tokens → Fine-grained tokens:

| Field | Value |
|---|---|
| Resource owner | `tsyche` (the account owning these repos) |
| Repository access | Select `dotfile-matrix`, `configgy-smalls`, and `scriptorium`; family users who may install the optional agent skills/scripts must also select `agentrc` |
| Permissions | Repository → **Contents: Read-only** (nothing else) |
| Expiration | Shortest offered — a bootstrap takes minutes, not days |

Enter it at git's password prompt (the username is pre-filled). **Revoke it
once setup finishes** rather than waiting for expiry.

Employer machines skip agent configuration. Family machines clone the private
agent repository only when the optional history-free skills/scripts copy is
selected, so their token needs that additional repository in that case.

The token is never written to disk by these scripts, and cleanup after the
last clone purges git's credential cache, resets `credential.helper`, and
deletes any macOS Keychain entry. That last step matters: macOS ships
`credential.helper=osxkeychain` in its **system** gitconfig, which would
otherwise persist your token in the login Keychain permanently — and being
system-level, it survives anything set or unset at `--global` scope.

## What it sets up

| Repo | Destination | What it is |
|------|-------------|------------|
| `dotfile-matrix` | `~/Repos/dotfile-matrix` | Shell config, Brewfile, symlinks, SSH keys |
| `agentrc` | `~/.agentrc/.git` + `$HOME` worktree | Portable Claude/Codex configuration and shared agent tooling |
| `configgy-smalls` | `~/Repos/configgy-smalls` | GUI app preferences (iTerm2, etc.) |
| `scriptorium` | `~/Repos/scriptorium` | Personal scripts |

After cloning, hands off to `setup-all.sh` (syncs the repos, sets up `~/Scripts`
and `~/.agents/skills` symlinks, purges the GitHub credential once nothing needs
it anymore), which in turn runs `dotfile-matrix/bootstrap.sh` for everything else
(packages, SSH key generation, runtimes, etc.). `setup-all.sh` is also its own
standalone entry point — safe to re-run directly (`~/Repos/init-me/setup-all.sh`)
any time you just want to re-sync/re-run setup without repeating the credential
flow from scratch.

Employer-owned and family/other-person machines don't get the full set above — both are meant to hold less of *your* personal material, just less of it:

| Machine type | `agentrc` | `configgy-smalls` | `scriptorium` |
|---|---|---|---|
| Personal | Full `$HOME` worktree | Full clone | Full clone |
| Employer-owned | Skipped — Claude Code itself isn't installed there either | Full clone | Full clone |
| Family/other-person | Optional — skills/scripts copied only (no git history, no memory/plans), prompted at setup | Skipped | Skipped |

Family/other-person machines also install family-relevant tools (Syncthing, a personal VPN client, Cryptomator, Steam, SimpleX, etc.) by default rather than excluding them — the opposite default from employer-owned machines. Two more prompts on macOS ask whether to also install other dev tools (devin-desktop, Antigravity, Beekeeper Studio, Bruno, Charles, UTM) and AI coding tools (Claude Code, Claude desktop, Codex, Grok Build); declining either just adds them to `~/.install-exclude.local`, editable anytime.

## Migrating a legacy personal machine

Do not pull `agentrc` while its Git metadata still lives at
`~/.claude/.git`: the migrated repository uses `$HOME` as its worktree, so a
pull through the old `~/.claude` worktree can place files under the wrong
paths. Close all agent sessions, update the normal `init-me` checkout, and
preserve the old metadata before installing:

If `.agentrc`, `.claude`, or `.codex` already appears *inside* `~/.claude`, a
migrated tree was pulled through the wrong worktree root. The installer detects
that state and stops. Preserve and quarantine the five misplaced tracked paths
before installing; this leaves real live configuration and runtime state under
`~/.claude` untouched:

```bash
git -C "$HOME/Repos/init-me" pull --ff-only

wrong_root_backup="$HOME/agentrc-wrong-root-backup-$(date +%Y%m%d%H%M%S)"
mkdir -p "$wrong_root_backup"
git -C "$HOME/.claude" status --short --branch | tee "$wrong_root_backup/status.txt"
git -C "$HOME/.claude" bundle create "$wrong_root_backup/clauderc.bundle" --all
git -C "$HOME/.claude" bundle verify "$wrong_root_backup/clauderc.bundle"
mv "$HOME/.claude/.git" "$wrong_root_backup/clauderc.git"

for wrong_root_path in .agentrc .claude .codex .gitignore README.md; do
  if [[ -e "$HOME/.claude/$wrong_root_path" \
    || -L "$HOME/.claude/$wrong_root_path" ]]; then
    mv "$HOME/.claude/$wrong_root_path" "$wrong_root_backup/$wrong_root_path"
  fi
done

"$HOME/Repos/init-me/scripts/install-agentrc.sh" \
  git@github.com:tsyche/agentrc.git
```

For a normal legacy checkout with none of those nested directories, use this
sequence instead:

```bash
git -C "$HOME/Repos/init-me" pull --ff-only

legacy_backup="$HOME/agentrc-legacy-backup-$(date +%Y%m%d%H%M%S)"
mkdir -p "$legacy_backup"
git -C "$HOME/.claude" status --short --branch | tee "$legacy_backup/status.txt"
git -C "$HOME/.claude" log --oneline '@{u}..HEAD' > "$legacy_backup/local-commits.txt"
git -C "$HOME/.claude" diff --binary > "$legacy_backup/working-tree.patch"
git -C "$HOME/.claude" diff --cached --binary > "$legacy_backup/index.patch"
git -C "$HOME/.claude" bundle create "$legacy_backup/clauderc.bundle" --all
git -C "$HOME/.claude" bundle verify "$legacy_backup/clauderc.bundle"
mv "$HOME/.claude/.git" "$legacy_backup/clauderc.git"

"$HOME/Repos/init-me/scripts/install-agentrc.sh" \
  git@github.com:tsyche/agentrc.git
```

The installer preserves conflicting tracked files under a timestamped
`~/agentrc-bootstrap-backup/` directory. Review that directory, the recorded
local commits, and the new repository status before launching an agent or
allowing session sync:

```bash
git -C "$HOME" --git-dir="$HOME/.agentrc/.git" --work-tree="$HOME" \
  status --short --branch
```

New local-only files may remain visible in the new worktree; modified tracked
files are restored from the remote while their prior versions remain in the
bootstrap backup for deliberate conflict resolution.

## When a run fails

Every run writes three things. Check them in this order:

| File | Answers |
|---|---|
| `~/bootstrap-steps.log` | **How far did it get?** One line per section entered, plus `COMPLETE` only on a clean finish. Its absence means it died before the first section. |
| `~/bootstrap-error.log` | **Why did it stop?** The line number and command from `bootstrap.sh`'s error trap. |
| `~/bootstrap-logs/*.log` | Full transcript of the run, timestamped. |

The first two are written by direct file append specifically so they survive
a crash — the transcript goes through `tee`, which can lose buffered output
at exactly the moment a script dies.

Failures are reported with the real exit code and what it means, not a
generic "had issues": a missing or non-executable script gets its own
explicit message before it's even invoked; `rc=126` means it couldn't be
executed; `rc=127` means it ran but called a command that doesn't exist;
anything else reports the raw exit code.

To run `bootstrap.sh` alone and watch it live, bypassing the log capture:

```bash
cd ~/Repos/dotfile-matrix
BOOTSTRAP_LOG_ACTIVE=1 MACHINE_TYPE=employer bash -x bootstrap.sh
```

`BOOTSTRAP_LOG_ACTIVE=1` skips the internal `tee`, so everything goes
straight to the terminal; `bash -x` prints each command as it executes.

## Platform support

| Platform | Status |
|----------|--------|
| macOS | ✅ Supported |
| Linux | ✅ Supported |
| Windows | 🔜 Future — run inside WSL or Git Bash in the meantime |
