# init-me

One command to bootstrap a new machine. Installs Homebrew, authenticates GitHub, clones all config repos, and kicks off the full setup.

## Usage

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tsyche/init-me/main/init.sh)
```

You'll be prompted twice:
1. Homebrew install (sudo password, macOS only first time)
2. `gh auth login` (opens browser — log in and approve)

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
