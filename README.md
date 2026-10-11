# Setup

New computer setup script with my preferences. Designed to run on either macOS or
Ubuntu/Debian.

This is public so I can pull without setting up GitHub keys.

***This is not intended for public use.***

## Installation

One line installation:

```sh
git clone https://github.com/briancpark/setup.git && cd setup && ./setup.sh --personal
```

### Profiles

Pick exactly one profile:

```sh
./setup.sh --personal
./setup.sh --company
./setup.sh --remote
./setup.sh --embedded
```

| Profile | Description |
|---|---|
| `--personal` | Personal machines. Everything: desktop packages and TeX, Docker, CUDA (if an NVIDIA GPU is present), conda, Tailscale, Chrome, Copilot, AI coding tools. |
| `--company` | Work machines. Same as personal minus the personal proprietary extras (AI coding tools, Copilot, Chrome). On macOS also runs a private company setup repo (`COMPANY_GIT_URL`, or prompted). See [LICENSES.md](LICENSES.md). |
| `--remote` | Remote/shared machines like supercomputers. Core packages, zsh, vim, conda. No Docker, CUDA, TeX or Tailscale. Skips anything needing `sudo` if you don't have it. |
| `--embedded` | Minimal, e.g. Raspberry Pi. Core packages, zsh, vim, Tailscale. |

The full table lives at the top of `setup.sh` (the `flags=` rows).

### Options

| Option | Description |
|---|---|
| `--school` | Also clone coursework repos (over SSH, needs GitHub keys) and create their conda envs. |
| `--update` | macOS: install pending system updates first. |
| `--verbose` | Echo every command as it runs. |

Environment variables: `TAILSCALE_AUTHKEY` for an unattended `tailscale up`, and
`COMPANY_GIT_URL` for `--company` on macOS.

The script is idempotent: re-running skips anything already installed. Best-effort steps
that fail are listed at the end, and the script then exits non-zero.

## Layout

| File | Purpose |
|---|---|
| `setup.sh` | The only entrypoint. |
| `Aptfile` / `Aptfile.desktop` | apt packages (core / personal+company only), grouped by license. |
| `Brewfile` | Homebrew bundle for macOS, grouped by license. |
| `LICENSES.md` | License inventory for everything installed. |
| `.zshrc`, `.zsh_aliases`, `.p10k.zsh`, `.tmux.conf`, `.gitignore_global` | Copied to `$HOME` on every run. |
| `.vimrc`, `.vimrc.plug` | Copied to `$HOME` only if not already present. |
| `ghostty_config` | macOS Ghostty config. |
| `bin/` | macOS helper scripts, copied to `~/bin`. |
| `bench/` | CPU/GPU microbenchmarks (see `bench/README.md`). |

SSH host config lives in the private `briancpark/ssh-config` repo and is synced into
`~/.ssh/config` by `setup.sh`.

## Configuration

I will forget what each part does, so I document their purposes here.

### oh-my-zsh

A better shell for productivity.

Plugins (see `plugins=(...)` in `.zshrc`)
* git, sudo, python, virtualenv, dotenv, macos
* bundler, rake, rbenv, ruby
* zsh-autosuggestions
* zsh-syntax-highlighting

Themes
* Powerlevel10k (config in `.p10k.zsh`)
* Needs a Nerd Font for icons: MesloLGS NF is installed on Linux, and the Meslo Nerd Font
  cask on macOS
