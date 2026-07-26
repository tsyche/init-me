# init-me

One command to bootstrap a new machine. Installs Homebrew, authenticates GitHub, clones all config repos, and kicks off the full setup.

## Usage

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tsyche/init-me/main/init.sh || curl -fsSL https://gitlab.com/tsyche/init-me/-/raw/main/init.sh)
```

Tries GitHub first, falls back to the GitLab mirror if that fetch fails —
same script either way, kept in sync manually for now.

You'll be prompted for:
1. What kind of machine this is (personal vs. employer-owned — changes the
   credential mechanism used below, see `init.sh` for details)
2. Homebrew install (sudo password, macOS only first time)
3. Personal machines: `gh auth login` (opens browser — log in and approve).
   Employer-owned machines: a GitHub Personal Access Token instead (no gh
   CLI, no SSH keys tied to your own GitHub identities)

Everything else is automated.

## What it sets up

| Repo | Destination | What it is |
|------|-------------|------------|
| `dotfile-matrix` | `~/Repos/dotfile-matrix` | Shell config, Brewfile, symlinks, SSH keys |
| `clauderc` | `~/.claude` | Claude Code skills, hooks, CLAUDE.md |
| `configgy-smalls` | `~/Repos/configgy-smalls` | GUI app preferences (iTerm2, etc.) |
| `scriptorium` | `~/Repos/scriptorium` | Personal scripts |

After cloning, hands off to `dotfile-matrix/bootstrap.sh` which handles everything else (packages, symlinks, SSH key generation, runtimes, etc.).

## Platform support

| Platform | Status |
|----------|--------|
| macOS | ✅ Supported |
| Linux | ✅ Supported |
| Windows | 🔜 Future — run inside WSL or Git Bash in the meantime |
