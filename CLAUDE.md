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
./setup.sh --company           # work machine (MIT-licensed packages only)
./setup.sh --remote            # remote/shared machines (e.g. supercomputers)
./setup.sh --embedded          # minimal, e.g. Raspberry Pi
./setup.sh --personal --school # add --school to also clone coursework repos + create conda envs
```

`setup.sh` requires at least one argument or it exits. It is idempotent — guards check for
existing installs/files before acting, so re-running is safe.

There is no build, lint, or test suite. "Validating" a change means running `setup.sh`
(or the relevant section) on the target OS, or at minimum `bash -n setup.sh` to syntax-check.
The script runs under `set -euo pipefail`, so any unguarded failure aborts the whole run.

## Architecture

`setup.sh` is the orchestrator and the only executable entrypoint. Its flow:

1. **Arg parsing** sets two variables: `level` (install profile) and `school` (0/1).
2. **Function definitions** — `configure_ssh_key`, `vim_setup`, `git_setup`, `docker_setup`,
   `conda_setup` — are declared but most are called only at the very end.
3. **OS branch** — a large `if` on `$OSTYPE` splits into a Linux (apt) path and a macOS
   (Homebrew) path, with a further `uname -m` split for Apple Silicon vs. deprecated Intel.
4. **Common tail** — `git_setup`, optional `--school` repo clones, `conda_setup`, `vim_setup`
   run for both OSes.

Config files in the repo root and `bin/` are the payload the script copies into place:

- `.zshrc`, `.zsh_aliases`, `.p10k.zsh` → copied to `$HOME`
- `ghostty_config` → `~/Library/Application Support/com.mitchellh.ghostty/config` (macOS only)
- `bin/*` → `~/bin/` (macOS Apple Silicon only), made executable
- `.gitignore_global` → referenced via `git config core.excludesfile` (not auto-copied)
- `.vimrc` / `.vimrc.plug` exist in-repo, but `vim_setup` actually pulls vimrc from the
  separate `briancpark/vim` repo — keep that in mind before editing the local copies.
- `config` is an SSH `~/.ssh/config` (named hosts like `pi`, `tinybox`, `jetson`) kept in this
  repo for reference. The live SSH config is managed separately: `ssh_config_setup` clones
  `git@github.com:briancpark/ssh-config.git` to `~/dev/ssh-config` and symlinks its `config`
  to `~/.ssh/config` (symlink, so `git pull`/`git push` there keeps machines in sync). It runs
  right after `git_setup` and depends on the GitHub SSH key from `configure_ssh_key`.

Package manifests:
- `Aptfile` (Linux) and `Brewfile` (macOS) list packages, grouped by software license in
  comments. The `--company`/MIT constraint is a manual discipline reflected in those license
  groupings, not enforced by code.

## Gotchas

- **The README's level numbering does not match the code.** README lists embedded=0,
  remote=1, company=2, personal=3, but `setup.sh` assigns `--personal`→1, `--company`→2,
  `--remote`→3, `--embedded`→4. The code is what runs. Several conditionals key off these
  numbers (e.g. `level -eq 1` = personal-only Chrome/helper installs, `level -eq 2`/`!= 2` =
  company gating), so changing the mapping requires auditing every `level` comparison.
- macOS-only features (Ghostty config, `bin/` helper copy, Rosetta) live inside the Apple
  Silicon branch and won't run on Linux or Intel Macs.
- `--school` clones repos over SSH (`git@github.com:...`) and so requires GitHub keys, unlike
  the HTTPS clones elsewhere.
