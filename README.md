# init-me

One command to bootstrap a new machine. Installs Homebrew, authenticates GitHub, clones all config repos, and kicks off the full setup.

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
| Repository access | Only select repositories: `dotfile-matrix`, `configgy-smalls`, `scriptorium` |
| Permissions | Repository → **Contents: Read-only** (nothing else) |
| Expiration | Shortest offered — a bootstrap takes minutes, not days |

Enter it at git's password prompt (the username is pre-filled). **Revoke it
once setup finishes** rather than waiting for expiry.

`clauderc` is deliberately absent from that list — it isn't cloned on either
machine type.

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
| `clauderc` | `~/.claude` | Claude Code skills, hooks, CLAUDE.md |
| `configgy-smalls` | `~/Repos/configgy-smalls` | GUI app preferences (iTerm2, etc.) |
| `scriptorium` | `~/Repos/scriptorium` | Personal scripts |

After cloning, hands off to `dotfile-matrix/bootstrap.sh` which handles everything else (packages, symlinks, SSH key generation, runtimes, etc.).

Employer-owned and family/other-person machines don't get the full set above — both are meant to hold less of *your* personal material, just less of it:

| Machine type | `clauderc` | `configgy-smalls` | `scriptorium` |
|---|---|---|---|
| Personal | Full clone | Full clone | Full clone |
| Employer-owned | Skipped — Claude Code itself isn't installed there either | Full clone | Full clone |
| Family/other-person | Optional — skills/scripts copied only (no git history, no memory/plans), prompted at setup | Skipped | Skipped |

Family/other-person machines also install family-relevant tools (Syncthing, a personal VPN client, Cryptomator, Steam, SimpleX, etc.) by default rather than excluding them — the opposite default from employer-owned machines. Two more prompts on macOS ask whether to also install other dev tools (devin-desktop, Antigravity, Beekeeper Studio, Bruno, Charles, UTM) and AI coding tools (Claude Code, Claude desktop, Codex, Grok Build); declining either just adds them to `~/.install-exclude.local`, editable anytime.

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

Failures are reported with the real exit code (`rc=127` means the script was
never found and never ran; `rc=1` means it ran and failed) — not a generic
"had issues".

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
