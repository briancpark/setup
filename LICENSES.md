# Licenses

What `setup.sh` installs and under which license, so a work machine can be checked
against an employer's policy. This is a reference, not legal advice.

## Where licenses are recorded

- **Package manifests** — [`Aptfile`](Aptfile), [`Aptfile.desktop`](Aptfile.desktop) and
  [`Brewfile`](Brewfile) group packages by primary license and put the full
  [SPDX](https://spdx.org/licenses/) expression on every line. Those comments are the
  source of truth for packages; this file doesn't repeat them.
- **Everything else** — software `setup.sh` fetches directly (vendor repos, installers,
  git clones) is listed in the table below.

When adding a package, put it under the right license heading with its SPDX expression.
For Homebrew formulae, `brew info --json=v2 <name>` (or
`https://formulae.brew.sh/api/formula/<name>.json`) reports the license.

## Installed outside the manifests

Profiles: **P** personal, **C** company, **R** remote, **E** embedded.

| Software | License | Profiles | Notes |
|---|---|---|---|
| Homebrew | BSD-2-Clause | P C R E (macOS) | |
| Xcode Command Line Tools | Proprietary (Apple SLA) | P C R E (macOS) | |
| Rosetta 2 | Proprietary (Apple SLA) | P C R E (Apple Silicon) | |
| Oh My Zsh | MIT | P C R E | |
| Powerlevel10k | MIT | P C R E | |
| zsh-autosuggestions | MIT | P C R E | |
| zsh-syntax-highlighting | BSD-3-Clause | P C R E | |
| vim-plug | MIT | P C R E | |
| packer.nvim | MIT | P C R E | |
| MesloLGS NF fonts | Apache-2.0 | P C (Linux) | macOS gets the Nerd Font cask from the Brewfile |
| Powerline fonts | Per font (mostly OFL-1.1 / Apache-2.0) | P C | |
| Miniforge | BSD-3-Clause | P C R (+ `--school`) | conda-forge packages carry their own licenses |
| Tailscale (CLI + daemon) | BSD-3-Clause | P C E | Service use is under Tailscale's terms |
| Docker Engine (docker-ce, containerd, buildx, compose) | Apache-2.0 | P C (Linux) | Docker *Desktop* is not installed; it has separate commercial terms |
| NVIDIA CUDA Toolkit | Proprietary (NVIDIA CUDA EULA) | P C (Linux with NVIDIA GPU) | |
| copilot.vim | Proprietary (GitHub Copilot terms) | P R E | Excluded from company |
| Google Chrome | Proprietary (Google Chrome ToS) | P (Linux amd64) | Chromium (BSD-3-Clause + others) on ARM |
| Claude Code | Proprietary (Anthropic Commercial Terms) | P | |
| OpenAI Codex CLI | Apache-2.0 | P | |
| Google Antigravity | Proprietary (Google) | P | |

## Company profile

`--company` leaves out the personal proprietary extras: AI coding tools, Copilot, and
Chrome. It does **not** limit installs to MIT-licensed software. A usable dev machine
needs git, gcc, vim, tmux and others that are GPL, Vim or ISC licensed.

Copyleft obligations (GPL/LGPL) apply when software is *distributed*, not when it is used
as a local tool. Licenses worth a closer look under a strict policy:

- **Vagrant**: BUSL-1.1 (Brewfile). Source-available, not open source. Internal use is
  allowed; the restriction covers offering it as part of a competing commercial product.
- **nmap**: Nmap Public Source License (both manifests). Free for end-user use, but
  restricts redistribution in proprietary products. Some employers also restrict network
  scanners on corporate networks, which is a policy question rather than a license one.
- **NVIDIA CUDA Toolkit**: proprietary EULA.
- **TeX Live** (`texlive-full`, Aptfile.desktop): a collection with per-package licenses
  (LPPL, GPL, OFL, public domain, ...).
