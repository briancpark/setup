#!/bin/bash
# New-machine bootstrap for macOS and Ubuntu/Debian. See README.md for profiles and
# LICENSES.md for the license of everything this installs.
#
# NOTE: macOS ships bash 3.2 as /bin/bash, so avoid bash 4+ features in shared code
# (mapfile, associative arrays, ${var,,}).
set -eEuo pipefail
trap 'echo "setup.sh: aborted at line $LINENO: $BASH_COMMAND" >&2' ERR

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

###############
# CLI Arguments
###############

usage() {
    cat <<'EOF'
Usage: ./setup.sh <profile> [--school] [--update] [--verbose]

Profiles (pick exactly one):
  --personal   Personal machine: everything
  --company    Work machine: no personal/proprietary extras (AI CLIs, Copilot, Chrome)
  --remote     Remote/shared machine (e.g. supercomputer): lightweight, no system services
  --embedded   Minimal, e.g. Raspberry Pi

Options:
  --school     Also clone coursework repos and create their conda envs
  --update     macOS: install pending system updates (softwareupdate) first
  --verbose    Echo every command as it runs
  -h, --help   Show this help

Environment:
  TAILSCALE_AUTHKEY   Auth key for unattended `tailscale up`
  COMPANY_GIT_URL     --company on macOS: private setup repo (otherwise prompted)
EOF
}

profile=""
school=0
update=0
verbose=0

set_profile() {
    if [ -n "$profile" ] && [ "$profile" != "$1" ]; then
        echo "Error: only one profile allowed (got --$profile and --$1)." >&2
        exit 1
    fi
    profile="$1"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --personal|--company|--remote|--embedded) set_profile "${1#--}" ;;
        --school)  school=1 ;;
        --update)  update=1 ;;
        --verbose) verbose=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

if [ -z "$profile" ]; then
    echo "Error: a profile is required." >&2
    usage >&2
    exit 1
fi

if [ "$verbose" -eq 1 ]; then
    set -x
fi

# What each profile installs. Gate features on these, never on the profile name directly,
# so adding or changing a profile only means editing this table.
#   desktop:   GUI-ish/heavy packages (Aptfile.desktop, fonts, TeX)
#   docker:    Docker Engine (Linux)
#   cuda:      NVIDIA CUDA toolkit when a GPU is present (Ubuntu)
#   conda:     Miniforge
#   tailscale: Tailscale client
#   ai:        Claude Code, Codex, Antigravity (proprietary/personal)
#   copilot:   copilot.vim (proprietary GitHub service)
#   chrome:    Google Chrome (proprietary)
case "$profile" in
    #                 desktop docker cuda conda tailscale ai copilot chrome
    personal) flags=(1       1      1    1     1         1  1       1) ;;
    company)  flags=(1       1      1    1     1         0  0       0) ;;
    remote)   flags=(0       0      0    1     0         0  1       0) ;;
    embedded) flags=(0       0      0    0     1         0  1       0) ;;
esac
want_desktop=${flags[0]}
want_docker=${flags[1]}
want_cuda=${flags[2]}
want_conda=${flags[3]}
want_tailscale=${flags[4]}
want_ai=${flags[5]}
want_copilot=${flags[6]}
want_chrome=${flags[7]}

###############
# Helpers
###############

failures=()

warn() {
    echo "WARN: $*" >&2
}

# Run a best-effort command: on failure, record it for the end-of-run summary instead of
# aborting. Only pass simple commands -- bash disables `set -e` inside anything run in a
# `||` context, so a shell function passed here would keep going after its own errors.
try() {
    local desc="$1"
    shift
    if ! "$@"; then
        failures+=("$desc")
        warn "$desc failed (continuing)"
    fi
}

# Clone a repo unless the destination already exists.
clone_once() {
    local dest="${*: -1}"
    if [ ! -d "$dest" ]; then
        git clone "$@"
    fi
}

os_release() {
    # Print one field from /etc/os-release, e.g. `os_release ID`
    # shellcheck disable=SC1091
    (. /etc/os-release && eval "echo \"\${$1:-}\"")
}

have_sudo=0
check_sudo() {
    if command -v sudo &> /dev/null && sudo -v; then
        have_sudo=1
    else
        warn "No sudo access; skipping system packages and services."
    fi
}

###############
# Functions
###############

install_dotfiles() {
    cp "$REPO_DIR/.zshrc" "$HOME/.zshrc"
    cp "$REPO_DIR/.zsh_aliases" "$HOME/.zsh_aliases"
    cp "$REPO_DIR/.tmux.conf" "$HOME/.tmux.conf"
    cp "$REPO_DIR/.p10k.zsh" "$HOME/.p10k.zsh"
    cp "$REPO_DIR/.gitignore_global" "$HOME/.gitignore_global"
}

configure_ssh_key() {
    if [ ! -f "$HOME/.ssh/id_ed25519.pub" ]; then
        ssh-keygen -t ed25519 -C "me@briancpark.com"
        eval "$(ssh-agent -s)"
        ssh-add "$HOME/.ssh/id_ed25519"
        cat "$HOME/.ssh/id_ed25519.pub"
        echo "Please add the above SSH key to your GitHub account, then press Enter."
        read -r _
    fi
}

zsh_setup() {
    if ! command -v zsh &> /dev/null; then
        warn "zsh is not installed; skipping Oh My Zsh setup."
        failures+=("zsh setup (zsh missing)")
        return
    fi

    local zsh_custom="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

    # KEEP_ZSHRC: the installer otherwise replaces our ~/.zshrc with its template.
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        KEEP_ZSHRC=yes RUNZSH=no CHSH=no sh -c \
            "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    fi

    clone_once --depth=1 https://github.com/romkatv/powerlevel10k.git "$zsh_custom/themes/powerlevel10k"
    local plugin
    for plugin in zsh-autosuggestions zsh-syntax-highlighting; do
        clone_once --depth=1 "https://github.com/zsh-users/$plugin" "$zsh_custom/plugins/$plugin"
    done
}

linux_fonts_setup() {
    # MesloLGS NF, the font Powerlevel10k is designed for (macOS gets it from the Brewfile)
    local font_dir="$HOME/.local/share/fonts"
    local base="https://github.com/romkatv/powerlevel10k-media/raw/master"
    local style installed=0
    mkdir -p "$font_dir"
    for style in Regular Bold Italic "Bold Italic"; do
        if [ ! -f "$font_dir/MesloLGS NF $style.ttf" ]; then
            try "font MesloLGS NF $style" curl -fsSL -o "$font_dir/MesloLGS NF $style.ttf" \
                "$base/MesloLGS%20NF%20${style// /%20}.ttf"
            installed=1
        fi
    done
    if [ "$installed" -eq 1 ] && command -v fc-cache &> /dev/null; then
        fc-cache -f "$font_dir"
    fi
}

vim_setup() {
    ### Fonts (Powerline) ###
    if [ "$want_desktop" -eq 1 ]; then
        clone_once --depth=1 https://github.com/powerline/fonts "$HOME/fonts"
        if [ -x "$HOME/fonts/install.sh" ]; then
            try "Powerline fonts" "$HOME/fonts/install.sh"
        fi
    fi

    ### Vim Configuration ###
    # Don't clobber an existing config; .vimrc sources .vimrc.plug for vim-plug plugins.
    local f
    for f in .vimrc .vimrc.plug; do
        if [ ! -f "$HOME/$f" ]; then
            cp "$REPO_DIR/$f" "$HOME/$f"
        fi
    done

    # GitHub Copilot plugin
    if [ "$want_copilot" -eq 1 ]; then
        clone_once https://github.com/github/copilot.vim "$HOME/.vim/pack/github/start/copilot.vim"
    fi

    # vim-plug for Vim
    if [ ! -f "$HOME/.vim/autoload/plug.vim" ]; then
        curl -fsSLo "$HOME/.vim/autoload/plug.vim" --create-dirs \
            https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
    fi

    # Packer for Neovim
    clone_once --depth 1 https://github.com/wbthomason/packer.nvim \
        "$HOME/.local/share/nvim/site/pack/packer/start/packer.nvim"
}

git_setup() {
    git config --global user.name "Brian Park"
    git config --global user.email me@briancpark.com
    git config --global core.editor vim
    git config --global init.defaultBranch main
    git config --global core.excludesfile "$HOME/.gitignore_global"
}

ssh_config_setup() {
    # Sync SSH config from its dedicated repo. The repo's `config` is prepended to
    # ~/.ssh/config inside a marked block, preserving any host entries already in the
    # file. The block is delimited by markers so re-runs replace it in place rather than
    # stacking duplicates. Requires the GitHub SSH key from configure_ssh_key.
    local repo_dir="$HOME/dev/ssh-config"
    local target="$HOME/.ssh/config"
    local begin="# >>> ssh-config repo (managed by setup.sh) >>>"
    local end="# <<< ssh-config repo (managed by setup.sh) <<<"

    if [ ! -d "$repo_dir" ]; then
        if ! git clone git@github.com:briancpark/ssh-config.git "$repo_dir"; then
            warn "Failed to clone ssh-config repo (is the SSH key added to GitHub?); skipping."
            failures+=("ssh-config clone")
            return
        fi
    fi

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    if [ ! -f "$repo_dir/config" ]; then
        warn "No 'config' file found in $repo_dir; skipping SSH config sync."
        return
    fi

    if [ -f "$target" ]; then
        # Drop any previously-managed block, then prepend the fresh one above whatever
        # host entries the user already had.
        local remainder
        # Delete the old managed block, then strip any leading blank lines so the
        # spacer below doesn't accumulate across re-runs.
        remainder="$(sed "/^${begin}$/,/^${end}$/d" "$target" | sed '/./,$!d')"
        {
            echo "$begin"
            cat "$repo_dir/config"
            echo "$end"
            echo ""
            printf '%s\n' "$remainder"
        } > "${target}.tmp"
        mv "${target}.tmp" "$target"
        echo "Prepended ssh-config block to existing ~/.ssh/config"
    else
        {
            echo "$begin"
            cat "$repo_dir/config"
            echo "$end"
        } > "$target"
        echo "Created ~/.ssh/config from $repo_dir/config"
    fi
    chmod 600 "$target"
}

apt_install_file() {
    # Install every package listed in an Aptfile-style manifest (comments stripped).
    local file="$1"
    local pkgs=()
    local pkg
    while read -r pkg; do
        pkgs+=("$pkg")
    done < <(sed 's/#.*//' "$file" | awk 'NF { print $1 }')
    if [ "${#pkgs[@]}" -gt 0 ]; then
        sudo apt-get install -y "${pkgs[@]}"
    fi
}

docker_setup() {
    # Docker Engine from Docker's official apt repo (Ubuntu, Debian, Raspberry Pi OS)
    if command -v docker &> /dev/null; then
        echo "Docker is already installed."
        return
    fi

    local distro codename
    distro="$(os_release ID)"
    case "$distro" in
        ubuntu|debian|raspbian) ;;
        *) warn "Docker repo not available for '$distro'; skipping Docker."; return ;;
    esac
    codename="$(os_release UBUNTU_CODENAME)"
    codename="${codename:-$(os_release VERSION_CODENAME)}"

    echo "Installing Docker from official repository..."
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL "https://download.docker.com/linux/$distro/gpg" -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/$distro
Suites: $codename
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Add current user to docker group to run without sudo
    sudo usermod -aG docker "$USER"
    echo "Docker installed. You may need to log out and back in for group changes to take effect."
}

cuda_setup() {
    # NVIDIA CUDA toolkit from NVIDIA's apt repo, only when a GPU is present. PATH setup
    # for zsh lives in .zshrc (guarded on /usr/local/cuda existing).
    if ! command -v nvidia-smi &> /dev/null; then
        echo "No NVIDIA GPU detected. Skipping CUDA toolkit."
        return
    fi
    if dpkg -s cuda-toolkit &> /dev/null; then
        echo "CUDA toolkit is already installed."
        return
    fi
    if [ "$(os_release ID)" != "ubuntu" ]; then
        warn "CUDA repo setup only supports Ubuntu; skipping CUDA toolkit."
        return
    fi

    echo "NVIDIA GPU detected. Installing CUDA toolkit..."
    local arch repo_name tmpdeb
    case "$(dpkg --print-architecture)" in
        amd64) arch="x86_64" ;;
        arm64) arch="sbsa" ;;
        *) warn "Unsupported architecture for CUDA repo; skipping."; return ;;
    esac
    if grep -qi microsoft /proc/version 2>/dev/null; then
        repo_name="wsl-ubuntu"
    else
        # e.g. 24.04 -> ubuntu2404
        repo_name="ubuntu$(os_release VERSION_ID | tr -d .)"
    fi

    tmpdeb="$(mktemp --suffix=.deb)"
    if curl -fsSL -o "$tmpdeb" "https://developer.download.nvidia.com/compute/cuda/repos/${repo_name}/${arch}/cuda-keyring_1.1-1_all.deb"; then
        sudo dpkg -i "$tmpdeb"
        sudo apt-get update
        sudo apt-get install -y cuda-toolkit
        # bash isn't managed by this repo, so add PATH there directly
        if ! grep -q '/usr/local/cuda/bin' "$HOME/.bashrc" 2>/dev/null; then
            # shellcheck disable=SC2016  # expand at shell startup, not now
            printf '%s\n' 'export PATH=/usr/local/cuda/bin:$PATH' \
                'export LD_LIBRARY_PATH=/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}' \
                >> "$HOME/.bashrc"
        fi
    else
        warn "Failed to download NVIDIA cuda-keyring; skipping CUDA installation."
        failures+=("CUDA keyring download")
    fi
    rm -f "$tmpdeb"
}

chrome_setup() {
    # Google Chrome via Google's apt repo with a signed-by keyring so `apt upgrade` keeps
    # it current. Chrome for Linux is amd64-only — there is no official ARM build as of
    # 2026-06 — so on arm64/armhf fall back to Chromium.
    if command -v google-chrome &> /dev/null; then
        echo "Google Chrome is already installed."
        return
    fi

    local arch
    arch="$(dpkg --print-architecture)"
    case "$arch" in
        amd64)
            sudo install -m 0755 -d /etc/apt/keyrings
            if [ ! -f /etc/apt/keyrings/google-chrome.gpg ]; then
                curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
                    | sudo gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
            fi
            echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
                | sudo tee /etc/apt/sources.list.d/google-chrome.list > /dev/null
            sudo apt-get update
            sudo apt-get install -y google-chrome-stable
            ;;
        arm64|armhf)
            echo "No official Google Chrome build for $arch Linux; installing Chromium instead."
            if command -v chromium &> /dev/null || command -v chromium-browser &> /dev/null; then
                echo "Chromium is already installed."
            elif [ "$(os_release ID)" = "ubuntu" ] && command -v snap &> /dev/null; then
                # Ubuntu ships chromium as a snap (the apt package is just a shim)
                try "Chromium (snap)" sudo snap install chromium
            else
                # Debian / Raspberry Pi OS: native apt package is 'chromium'
                try "Chromium (apt)" sudo apt-get install -y chromium
            fi
            ;;
        *)
            warn "Unsupported architecture '$arch' for Chrome/Chromium; skipping."
            ;;
    esac
}

conda_setup() {
    # Miniforge (conda-forge's installer) appropriate to OS/arch. The zsh hook lives in
    # .zshrc; only bash gets `conda init` since bash isn't managed by this repo.
    local installer=""
    local prefix="$HOME/miniforge3"

    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64)  installer="Miniforge3-Linux-x86_64.sh" ;;
        Linux-aarch64) installer="Miniforge3-Linux-aarch64.sh" ;;
        Linux-armv7l)  installer="Miniforge3-Linux-armv7l.sh" ;;
        Darwin-arm64)  installer="Miniforge3-MacOSX-arm64.sh" ;;
        Darwin-x86_64) installer="Miniforge3-MacOSX-x86_64.sh" ;;
        *) warn "Unsupported platform $(uname -s)-$(uname -m) for Miniforge"; return ;;
    esac

    if [ ! -d "$prefix" ]; then
        echo "Installing Miniforge to $prefix"
        local tmp
        tmp="$(mktemp)"
        curl -fsSL -o "$tmp" "https://github.com/conda-forge/miniforge/releases/latest/download/$installer"
        bash "$tmp" -b -p "$prefix"
        rm -f "$tmp"
    else
        echo "Miniforge already installed at $prefix"
    fi

    local conda="$prefix/bin/conda"
    try "conda init bash" "$conda" init bash
    try "conda config" "$conda" config --set auto_activate_base false

    if [ "$school" -eq 1 ]; then
        # name=python-version. Best-effort: very old Pythons may be unavailable.
        local envs=(cs61a=3.8 cs61bl=3.9 cs61c=3.8 cs170=3.9 cs188=3.8 cs189=3.8
                    eecs16a=3.8 eecs16b=3.8 csc542=3.10 csc591=3.9 csc791=3.10
                    nums=3.8 mlx=3.11)
        local existing env name
        existing="$("$conda" env list | awk '!/^#/ { print $1 }')"
        for env in "${envs[@]}"; do
            name="${env%%=*}"
            if ! grep -qx "$name" <<< "$existing"; then
                try "conda env $name" "$conda" create -n "$name" "python=${env#*=}" -y
            fi
        done
    fi
}

school_setup() {
    # Coursework repos over SSH (needs the GitHub key from configure_ssh_key)
    local dir="$HOME/dev/school"
    local repos=(cs61a cs61bl cs61c cs70 eecs16a eecs16b ds100 cs152 cs161 cs162 cs170
                 cs188 cs189 cs267 csc512 csc542 csc561 csc591-007 csc591-026
                 csc791-025 csc766 ece786)
    local repo url
    mkdir -p "$dir"
    for repo in "${repos[@]}"; do
        url="git@github.com:briancpark/$repo.git"
        if [ -d "$dir/$repo" ]; then
            continue
        elif [ "$repo" = "cs152" ]; then
            # cs152's submodules are huge; don't pull them
            try "clone $repo" git clone "$url" "$dir/$repo"
        else
            try "clone $repo" git clone --recurse-submodules "$url" "$dir/$repo"
        fi
    done
}

ai_tools_setup() {
    # Claude Code (Anthropic) and OpenAI Codex are CLIs; Google Antigravity is a GUI IDE.

    ### Claude Code — official native installer, works on macOS + Linux ###
    if ! command -v claude &> /dev/null; then
        echo "Installing Claude Code..."
        try "Claude Code" bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
    else
        echo "Claude Code is already installed."
    fi

    ### Codex + Antigravity — install method differs per OS ###
    if [[ "$OSTYPE" == darwin* ]]; then
        if ! command -v codex &> /dev/null; then
            try "Codex" brew install --cask codex
        fi
        if [ ! -d "/Applications/Antigravity.app" ]; then
            try "Antigravity" brew install --cask antigravity-ide
        fi
    else
        if ! command -v codex &> /dev/null; then
            echo "Installing Codex..."
            try "Codex" bash -c 'curl -fsSL https://chatgpt.com/codex/install.sh | sh'
        fi

        # Google Antigravity IDE — no stable scriptable URL, so best-effort scrape the
        # current .deb link off the download page.
        if [ "$have_sudo" -eq 1 ] && ! command -v antigravity &> /dev/null && [ ! -d /opt/antigravity ]; then
            echo "Installing Antigravity..."
            local deb_url tmpdeb
            deb_url="$(curl -fsSL https://antigravity.google/download/linux 2>/dev/null \
                | grep -oE 'https://[^"]+\.deb' | head -n1 || true)"
            if [ -n "$deb_url" ]; then
                tmpdeb="$(mktemp --suffix=.deb)"
                if curl -fsSL -o "$tmpdeb" "$deb_url"; then
                    sudo dpkg -i "$tmpdeb" || sudo apt-get -f install -y
                else
                    failures+=("Antigravity download")
                fi
                rm -f "$tmpdeb"
            else
                warn "Could not resolve an Antigravity .deb URL; download it manually from https://antigravity.google/download/linux"
                failures+=("Antigravity (no .deb URL)")
            fi
        fi
    fi
}

tailscale_setup() {
    # For a fully unattended bring-up, export an auth key before running:
    #   TAILSCALE_AUTHKEY=tskey-auth-... ./setup.sh --personal
    # Without it, `tailscale up` falls back to interactive browser login.
    if ! command -v tailscale &> /dev/null; then
        echo "Installing Tailscale..."
        if [[ "$OSTYPE" == darwin* ]]; then
            # CLI/daemon via the Homebrew formula (the cask 'tailscale-app' is the GUI app)
            try "Tailscale" brew install tailscale
            try "tailscaled service" sudo brew services start tailscale
        elif [ "$have_sudo" -eq 1 ]; then
            # Official installer: adds the apt repo and starts tailscaled via systemd
            try "Tailscale" bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
        else
            return
        fi
    fi

    # Bring the machine onto the tailnet (skip if already connected)
    if command -v tailscale &> /dev/null && ! tailscale status &> /dev/null; then
        if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
            try "tailscale up" sudo tailscale up --auth-key="$TAILSCALE_AUTHKEY"
        else
            echo "Bringing up Tailscale (interactive browser login)..."
            try "tailscale up" sudo tailscale up
        fi
    fi
}

company_private_setup() {
    # Work-only setup kept in a private repo
    local url="${COMPANY_GIT_URL:-}"
    local dir="$HOME/company_private_setup"
    if [ -z "$url" ] && [ ! -d "$dir" ]; then
        read -r -p "Company private setup Git URL (blank to skip): " url
    fi
    if [ -n "$url" ]; then
        clone_once --recurse-submodules "$url" "$dir"
    fi
    if [ -x "$dir/setup_private.sh" ]; then
        # shellcheck disable=SC2016  # $1 expands inside the child bash
        try "company private setup" bash -c 'cd "$1" && ./setup_private.sh' _ "$dir"
    fi
}

linux_setup() {
    check_sudo

    if [ "$have_sudo" -eq 1 ]; then
        sudo apt-get update
        apt_install_file "$REPO_DIR/Aptfile"
        if [ "$want_desktop" -eq 1 ]; then
            apt_install_file "$REPO_DIR/Aptfile.desktop"
        fi
    fi

    zsh_setup
    if [ "$want_desktop" -eq 1 ]; then
        linux_fonts_setup
    fi
    configure_ssh_key

    if [ "$have_sudo" -eq 1 ]; then
        if [ "$want_chrome" -eq 1 ]; then
            chrome_setup
        fi
        if [ "$want_cuda" -eq 1 ]; then
            cuda_setup
        fi
        if [ "$want_docker" -eq 1 ]; then
            docker_setup
        fi

        local zsh_path
        zsh_path="$(command -v zsh || true)"
        if [ -n "$zsh_path" ] && [ "${SHELL:-}" != "$zsh_path" ]; then
            try "change login shell" sudo chsh -s "$zsh_path" "$USER"
        fi
    fi
}

macos_setup() {
    if [ "$update" -eq 1 ]; then
        try "softwareupdate" softwareupdate --install -a
    fi

    # Xcode Command Line Tools: the installer is a GUI dialog that returns immediately,
    # so wait for it before anything needs git/clang.
    if ! xcode-select -p &> /dev/null; then
        xcode-select --install || true
        echo "Waiting for Xcode Command Line Tools to finish installing..."
        until xcode-select -p &> /dev/null; do
            sleep 10
        done
    fi

    touch "$HOME/.hushlogin"

    local brew_prefix=/usr/local
    if [ "$(uname -m)" = "arm64" ]; then
        brew_prefix=/opt/homebrew
    else
        warn "Intel macOS is deprecated in this repo; continuing best-effort."
    fi

    if [ ! -x "$brew_prefix/bin/brew" ]; then
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    # Put brew on PATH for the rest of this run, and for future login shells
    eval "$("$brew_prefix/bin/brew" shellenv)"
    if ! grep -q "$brew_prefix/bin/brew shellenv" "$HOME/.zprofile" 2>/dev/null; then
        echo "eval \"\$($brew_prefix/bin/brew shellenv)\"" >> "$HOME/.zprofile"
    fi

    if [ "$(uname -m)" = "arm64" ] && ! arch -x86_64 /usr/bin/true 2>/dev/null; then
        softwareupdate --install-rosetta --agree-to-license
    fi

    ### Helper scripts (MLX tools, etc.) ###
    mkdir -p "$HOME/bin"
    cp "$REPO_DIR"/bin/* "$HOME/bin/"
    chmod +x "$HOME"/bin/*

    ### Ghostty terminal config ###
    local ghostty_dir="$HOME/Library/Application Support/com.mitchellh.ghostty"
    mkdir -p "$ghostty_dir"
    cp "$REPO_DIR/ghostty_config" "$ghostty_dir/config"

    configure_ssh_key
    try "brew bundle" brew bundle --file="$REPO_DIR/Brewfile"
    zsh_setup

    if [ "$profile" = "company" ]; then
        company_private_setup
    fi
}

summary() {
    echo
    if [ "${#failures[@]}" -eq 0 ]; then
        echo "setup.sh ($profile) finished with no failures."
        return 0
    fi
    echo "setup.sh ($profile) finished, but these steps failed:"
    printf '  - %s\n' "${failures[@]}"
    echo "Re-run after fixing; completed steps are skipped."
    return 1
}

###############
# Setup Script
###############

cd "$HOME"
install_dotfiles

case "$OSTYPE" in
    linux-gnu*) linux_setup ;;
    darwin*)    macos_setup ;;
    *) echo "Unknown OS type: $OSTYPE" >&2; exit 1 ;;
esac

git_setup
ssh_config_setup

if [ "$school" -eq 1 ]; then
    school_setup
fi
if [ "$want_conda" -eq 1 ] || [ "$school" -eq 1 ]; then
    conda_setup
fi
vim_setup
if [ "$want_tailscale" -eq 1 ]; then
    tailscale_setup
fi
if [ "$want_ai" -eq 1 ]; then
    ai_tools_setup
fi

summary || exit 1
