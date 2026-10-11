# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A personal dotfiles + new-machine bootstrap repo for Brian Park. A single `setup.sh`
installs packages and copies config files into `$HOME` to make a fresh macOS or Ubuntu
machine feel like home. It is public only so it can be cloned without SSH keys; it is not
intended for general public use.

## Running it

```sh
./setup.sh --personal          # full personal machine
./setup.sh --company           # work machine (no AI tools/Copilot/Chrome; see LICENSES.md)
./setup.sh --remote            # remote/shared machines (e.g. supercomputers)
./setup.sh --embedded          # minimal, e.g. Raspberry Pi
./setup.sh --personal --school # add --school to also clone coursework repos + create conda envs
```

Exactly one profile is required; unknown options and multiple profiles are errors.
Other flags: `--update` (macOS softwareupdate), `--verbose` (xtrace), `--help`.
It is idempotent — guards check for existing installs/files before acting, so re-running
is safe.

There is no build or test suite. Validate with `bash -n setup.sh` and
`shellcheck setup.sh bin/*.sh` (CI runs both: `.github/workflows/lint.yml`), and by
running the relevant section on the target OS.

## Architecture

`setup.sh` is the only executable entrypoint. It runs under `set -eEuo pipefail` with an
ERR trap, so unguarded failures abort. Best-effort steps go through `try "<desc>" cmd...`,
which records failures for the end-of-run summary (exit 1 if any failed). Only pass
simple commands to `try` — bash disables `set -e` inside functions run in a `||` context.

**macOS runs bash 3.2**, so no `mapfile`, associative arrays, or `${var,,}` in shared code,
and never expand a possibly-empty array with `"${arr[@]}"` (unbound under `set -u`).

Flow:

1. **Arg parsing** sets `profile` (personal|company|remote|embedded), `school`, `update`.
2. **Profile table** — one `flags=(...)` row per profile maps to `want_desktop`,
   `want_docker`, `want_cuda`, `want_conda`, `want_tailscale`, `want_ai`, `want_copilot`,
   `want_chrome`. Gate features on these `want_*` variables, not on the profile name
   (the only exception is `company_private_setup`).
3. **Main sequence** at the bottom: `install_dotfiles` → `linux_setup` or `macos_setup`
   → `git_setup` → `ssh_config_setup` → optional `school_setup` → `conda_setup` →
   `vim_setup` → `tailscale_setup` → `ai_tools_setup` → `summary`.
   - `linux_setup` checks for sudo once (`have_sudo`); without it, apt/Docker/CUDA/Chrome/
     chsh/Tailscale are skipped (for shared machines).
   - `macos_setup` waits for the Xcode CLT, installs Homebrew and `eval`s `brew shellenv`
     into the running session, then `brew bundle`.

Config files in the repo root and `bin/` are the payload:

- `.zshrc`, `.zsh_aliases`, `.tmux.conf`, `.p10k.zsh`, `.gitignore_global` → copied to
  `$HOME` on every run (overwriting). **Don't have setup.sh append to `~/.zshrc`** — it is
  overwritten next run. Put machine-conditional config in the repo `.zshrc` behind a guard
  instead (see the CUDA / conda / p10k blocks at its end). Oh My Zsh is installed with
  `KEEP_ZSHRC=yes` so it doesn't replace ours.
- `.vimrc`, `.vimrc.plug` → copied to `$HOME` only if absent. `.vimrc` sources `.vimrc.plug`
  (vim-plug plugins).
- `ghostty_config` → `~/Library/Application Support/com.mitchellh.ghostty/config` (macOS)
- `bin/*` → `~/bin/` (macOS), made executable
- SSH config is not in this repo: `ssh_config_setup` clones
  `git@github.com:briancpark/ssh-config.git` to `~/dev/ssh-config` and prepends its `config`
  into `~/.ssh/config` inside a marked block (`# >>> ssh-config repo ... >>>` /
  `# <<< ... <<<`), preserving other host entries. The markers make it idempotent. It
  depends on the GitHub SSH key from `configure_ssh_key`.

Package manifests and licenses:
- `Aptfile` (all Linux profiles) and `Aptfile.desktop` (`want_desktop`) are plain lists;
  `apt_install_file` strips `#` comments. `Brewfile` is a `brew bundle` file (`brew "x"`,
  `cask "y"`) for every macOS profile.
- Every manifest line carries its SPDX license in a trailing comment, grouped under license
  headings. `LICENSES.md` lists everything installed outside the manifests (vendor repos,
  installers, clones) with per-profile coverage. Keep both up to date when adding software.
  The company profile does not enforce a license allowlist; see LICENSES.md.

## Gotchas

- macOS-only features (Ghostty config, `bin/` copy, Rosetta) live in `macos_setup`.
- Docker supports Ubuntu/Debian/Raspberry Pi OS repos; CUDA setup is Ubuntu-only.
- `--school` clones repos over SSH (`git@github.com:...`) and so requires GitHub keys, unlike
  the HTTPS clones elsewhere.
