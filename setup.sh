#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

###############
# CLI Arguments
###############

# Initialize our own variables
school=0
level=0
verbose=0

if [ "$#" -eq 0 ]; then
    echo "No arguments provided. Please provide an argument."
    echo "Examples: --personal, --company, --remote, --embedded, optionally with --school or --verbose"
    exit 1
fi

# Robust option parsing
while [[ $# -gt 0 ]]; do
    case "$1" in
        --school)
            school=1
            shift
            ;;
        --verbose)
            verbose=1
            shift
            ;;
        --personal)
            level=1
            shift
            ;;
        --company)
            level=2
            shift
            ;;
        --remote)
            level=3
            shift
            ;;
        --embedded)
            level=4
            shift
            ;;
        *)
            echo "Unknown option: $1 (ignored)"
            shift
            ;;
    esac
done

# --verbose: echo every command as it runs (native bash xtrace)
if [ "$verbose" -eq 1 ]; then
    set -x
fi

###############
# Functions
###############

configure_ssh_key() {
    # SSH key configuration
    if ! [ -f ~/.ssh/id_ed25519.pub ]; then
        ssh-keygen -t ed25519 -C "me@briancpark.com"
        eval "$(ssh-agent -s)"
        ssh-add ~/.ssh/id_ed25519
        cat ~/.ssh/id_ed25519.pub
        echo "Please add the above SSH key to your GitHub account."
        read response
    fi
}

vim_setup() {
    ### Fonts (Powerline) ###
    if [ ! -d "$HOME/fonts" ]; then
        git clone https://github.com/powerline/fonts "$HOME/fonts"
    fi
    pushd "$HOME/fonts" >/dev/null
    if [ -x ./install.sh ]; then
        ./install.sh
    fi
    popd >/dev/null

    ### Vim Configuration ###
    # Use HTTPS to avoid requiring SSH keys on fresh machines
    if [ ! -f "$HOME/.vimrc" ]; then
        git clone https://github.com/briancpark/vim.git "$HOME/vim"
        if [ -f "$HOME/vim/vimrc" ]; then
            cp "$HOME/vim/vimrc" "$HOME/.vimrc"
        fi
        rm -rf "$HOME/vim"
    fi

    # GitHub Copilot plugin (skip on company machines)
    if [[ "$level" != 2 ]]; then
        if [ ! -d "$HOME/.vim/pack/github/start/copilot.vim" ]; then
            git clone https://github.com/github/copilot.vim "$HOME/.vim/pack/github/start/copilot.vim"
        fi
    fi

    # vim-plug for Vim
    if [ ! -f "$HOME/.vim/autoload/plug.vim" ]; then
        curl -fLo "$HOME/.vim/autoload/plug.vim" --create-dirs \
            https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
    fi

    # Packer for Neovim
    if [ ! -d "$HOME/.local/share/nvim/site/pack/packer/start/packer.nvim" ]; then
        git clone --depth 1 https://github.com/wbthomason/packer.nvim \
            "$HOME/.local/share/nvim/site/pack/packer/start/packer.nvim"
    fi
}

git_setup() {
    ### Git Repositories ###
    git config --global user.name "Brian Park"
    git config --global user.email me@briancpark.com
    git config --global core.editor vim
    git config --global init.defaultBranch main
    git config --global core.excludesfile ~/.gitignore_global
}

ssh_config_setup() {
    # Sync SSH config from its dedicated repo. The config is symlinked (not copied) so
    # `git pull`/`git push` in the repo keeps ~/.ssh/config in sync across machines.
    # Requires the GitHub SSH key from configure_ssh_key to already be in place.
    local repo_dir="$HOME/dev/ssh-config"

    if [ ! -d "$repo_dir" ]; then
        if ! git clone git@github.com:briancpark/ssh-config.git "$repo_dir"; then
            echo "Failed to clone ssh-config repo (is the SSH key added to GitHub?); skipping."
            return
        fi
    fi

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    if [ -f "$repo_dir/config" ]; then
        ln -sfn "$repo_dir/config" "$HOME/.ssh/config"
        chmod 600 "$repo_dir/config"
        echo "Linked ~/.ssh/config -> $repo_dir/config"
    else
        echo "No 'config' file found in $repo_dir; skipping SSH config link."
    fi
}

docker_setup() {
    # Install Docker using official Docker repository
    if command -v docker &> /dev/null; then
        echo "Docker is already installed."
        return
    fi

    echo "Installing Docker from official repository..."

    # Add Docker's official GPG key
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    # Add the repository to Apt sources
    sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Add current user to docker group to run without sudo
    sudo usermod -aG docker "$USER"
    echo "Docker installed. You may need to log out and back in for group changes to take effect."
}

conda_setup() {
    # Install Miniforge (Conda) appropriate to OS/arch
    local installer=""
    local prefix="$HOME/miniforge3"

    case "$(uname -s)" in
        Linux)
            case "$(uname -m)" in
                x86_64)   installer="Miniforge3-Linux-x86_64.sh" ;;
                aarch64)  installer="Miniforge3-Linux-aarch64.sh" ;;
                armv7l)   installer="Miniforge3-Linux-armv7l.sh" ;;
                *)        echo "Unsupported Linux arch $(uname -m) for Miniforge" ; return ;;
            esac
            ;;
        Darwin)
            case "$(uname -m)" in
                arm64)    installer="Miniforge3-MacOSX-arm64.sh" ;;
                x86_64)   installer="Miniforge3-MacOSX-x86_64.sh" ;;
                *)        echo "Unsupported macOS arch $(uname -m) for Miniforge" ; return ;;
            esac
            ;;
        *) echo "Unsupported OS $(uname -s)" ; return ;;
    esac

    if [ ! -d "$prefix" ]; then
        echo "Installing Miniforge to $prefix"
        curl -L -o "/tmp/$installer" "https://github.com/conda-forge/miniforge/releases/latest/download/$installer"
        bash "/tmp/$installer" -b -p "$prefix"
    else
        echo "Miniforge already installed at $prefix"
    fi

    # Ensure conda on PATH for this session
    export PATH="$prefix/bin:$PATH"

    # Initialize conda for bash and zsh (adds shell hooks)
    "$prefix/bin/conda" init bash zsh || true
    "$prefix/bin/conda" config --set auto_activate_base false || true

    if [ "$school" -eq 1 ]; then
        # Create school environments (best-effort; some very old Python versions may be unavailable)
        conda create -n cs61a python=3.8 -y || true
        conda create -n cs61bl python=3.9 -y || true
        conda create -n cs61c python=3.8 -y || true
        conda create -n cs170 python=3.9 -y || true
        conda create -n cs188 python=3.8 -y || true
        conda create -n cs189 python=3.8 -y || true
        conda create -n eecs16a python=3.8 -y || true
        conda create -n eecs16b python=3.8 -y || true
        conda create -n csc542 python=3.10 -y || true
        conda create -n csc591 python=3.9 -y || true
        conda create -n csc791 python=3.10 -y || true
        conda create -n nums python=3.8 -y || true
        conda create -n mlx python=3.11 -y || true
    fi
}

ai_tools_setup() {
    # AI coding assistants — personal machines only.
    # Claude Code (Anthropic) and OpenAI Codex are CLIs; Google Antigravity is a GUI IDE.

    ### Claude Code — official native installer, works on macOS + Linux ###
    if ! command -v claude &> /dev/null; then
        echo "Installing Claude Code..."
        curl -fsSL https://claude.ai/install.sh | bash
    else
        echo "Claude Code is already installed."
    fi

    ### Codex + Antigravity — install method differs per OS ###
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # OpenAI Codex CLI (Homebrew cask; the homebrew/core formula is gone)
        if ! command -v codex &> /dev/null; then
            echo "Installing Codex..."
            brew install --cask codex 2>/dev/null || true
        else
            echo "Codex is already installed."
        fi

        # Google Antigravity IDE (Homebrew cask)
        if [ ! -d "/Applications/Antigravity.app" ]; then
            echo "Installing Antigravity..."
            brew install --cask antigravity-ide 2>/dev/null || true
        else
            echo "Antigravity is already installed."
        fi

    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # OpenAI Codex CLI (official curl installer)
        if ! command -v codex &> /dev/null; then
            echo "Installing Codex..."
            curl -fsSL https://chatgpt.com/codex/install.sh | sh
        else
            echo "Codex is already installed."
        fi

        # Google Antigravity IDE — no stable scriptable URL, so best-effort scrape the
        # current .deb link off the download page. Verify manually if this is skipped.
        if ! command -v antigravity &> /dev/null && [ ! -d "/opt/antigravity" ]; then
            echo "Installing Antigravity..."
            deb_url=$(curl -fsSL https://antigravity.google/download/linux 2>/dev/null \
                | grep -oE 'https://[^"]+\.deb' | head -n1 || true)
            if [ -n "$deb_url" ]; then
                tmpdeb=/tmp/antigravity.deb
                if curl -fL -o "$tmpdeb" "$deb_url"; then
                    sudo dpkg -i "$tmpdeb" || sudo apt-get -f install -y
                    rm -f "$tmpdeb"
                fi
            else
                echo "Could not resolve an Antigravity .deb URL automatically."
                echo "Download it manually from https://antigravity.google/download/linux"
            fi
        else
            echo "Antigravity is already installed."
        fi
    fi
}

tailscale_setup() {
    # Tailscale on every machine. For a fully unattended bring-up, export an auth key
    # before running:  TAILSCALE_AUTHKEY=tskey-auth-... ./setup.sh --personal
    # Without it, `tailscale up` falls back to interactive browser login.

    ### Install ###
    if ! command -v tailscale &> /dev/null; then
        echo "Installing Tailscale..."
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # CLI/daemon via the Homebrew formula (the cask 'tailscale-app' is the GUI app)
            brew install tailscale 2>/dev/null || true
            sudo brew services start tailscale || true
        elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
            # Official installer: adds the apt repo and starts tailscaled via systemd
            curl -fsSL https://tailscale.com/install.sh | sh
        fi
    else
        echo "Tailscale is already installed."
    fi

    ### Bring the machine onto the tailnet (skip if already connected) ###
    if command -v tailscale &> /dev/null && ! tailscale status &> /dev/null; then
        if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
            echo "Connecting to Tailscale with auth key..."
            sudo tailscale up --auth-key="$TAILSCALE_AUTHKEY"
        else
            echo "Bringing up Tailscale (interactive browser login)..."
            sudo tailscale up
        fi
    fi
}


###############
# Setup Script
###############

cp "$REPO_DIR/.zshrc" "$HOME/.zshrc"
cp "$REPO_DIR/.zsh_aliases" "$HOME/.zsh_aliases"

# We start and install everything in the home directory
cd $HOME

# Install OS-specific packages

### Linux ###
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    sudo apt update
    if [ -f "$REPO_DIR/Aptfile" ]; then
        # Install packages from Aptfile (filter out comments and blank lines)
        grep -v '^#' "$REPO_DIR/Aptfile" | grep -v '^$' | xargs sudo apt install -y
    else
        echo "No Aptfile found. Skipping bulk apt installs."
    fi

    # Install Oh My Zsh first (needed before plugins/themes)
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    fi

    if [ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k" ]; then
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k
    fi
    plugins=(zsh-autosuggestions zsh-syntax-highlighting)
    for plugin in "${plugins[@]}"; do
        if [ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/$plugin" ]; then
            git clone https://github.com/zsh-users/$plugin ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/$plugin
        fi
    done

    # Download fonts only if not already present
    mkdir -p "$HOME/.local/share/fonts"
    if [ ! -f "$HOME/.local/share/fonts/MesloLGS NF Regular.ttf" ]; then
        curl -fL --create-dirs -o "$HOME/.local/share/fonts/MesloLGS NF Regular.ttf" https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Regular.ttf
        curl -fL --create-dirs -o "$HOME/.local/share/fonts/MesloLGS NF Bold.ttf" https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold.ttf
        curl -fL --create-dirs -o "$HOME/.local/share/fonts/MesloLGS NF Italic.ttf" https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Italic.ttf
        curl -fL --create-dirs -o "$HOME/.local/share/fonts/MesloLGS NF Bold Italic.ttf" https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold%20Italic.ttf
        fc-cache -fv
    fi

    configure_ssh_key

    ### External Installations ###
    # Google Chrome
    # only on personal
    if [ "$level" -eq 1 ]; then
        if ! command -v google-chrome &> /dev/null; then
            wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
            sudo apt install ./google-chrome-stable_current_amd64.deb -y
            rm google-chrome-stable_current_amd64.deb
        else
            echo "Google Chrome is already installed."
        fi

        # Other installation
        # sudo snap install --classic code 
        # if ! command -v code &> /dev/null; then
        #     sudo snap install --classic code
        # fi
        # sudo snap install --classic heroku
        # if ! command -v heroku &> /dev/null; then
        #     sudo snap install --classic heroku
        # fi
    fi

    # Remove old Anaconda scraping line (deleted)

    # Detect NVIDIA GPU and install NVIDIA toolkit
    if command -v nvidia-smi &> /dev/null; then
        # Skip if cuda-toolkit is already installed
        if ! dpkg -l cuda-toolkit &> /dev/null; then
            echo "NVIDIA GPU detected. Installing NVIDIA toolkit and developer packages..."
            # Map dpkg architecture to NVIDIA's naming convention
            dpkg_arch=$(dpkg --print-architecture)
            case "$dpkg_arch" in
                amd64) arch="x86_64" ;;
                arm64) arch="sbsa" ;;
                *) arch="$dpkg_arch" ;;
            esac
            # Get Ubuntu version (e.g., 22 for 22.04) - use /etc/os-release for WSL compatibility
            if [ -f /etc/os-release ]; then
                ubuntu_ver=$(. /etc/os-release && echo "${VERSION_ID}" | cut -d. -f1)
            else
                ubuntu_ver=$(lsb_release -sr | cut -d. -f1)
            fi
            # For WSL, use wsl-ubuntu repo if available, otherwise fallback to ubuntu repo
            tmpdeb=/tmp/cuda-keyring.deb
            # Try WSL-specific repo first, then fallback to standard Ubuntu repo
            if grep -qi microsoft /proc/version 2>/dev/null; then
                repo_name="wsl-ubuntu"
            else
                repo_name="ubuntu${ubuntu_ver}"
            fi
            if curl -fL -o "$tmpdeb" "https://developer.download.nvidia.com/compute/cuda/repos/${repo_name}/${arch}/cuda-keyring_1.1-1_all.deb"; then
                sudo dpkg -i "$tmpdeb"
                sudo apt update
                sudo apt install -y cuda-toolkit
                # Only add PATH exports if not already present
                if ! grep -q '/usr/local/cuda/bin' ~/.bashrc 2>/dev/null; then
                    echo 'export PATH=/usr/local/cuda/bin:$PATH' >> ~/.bashrc
                fi
                if ! grep -q '/usr/local/cuda/lib64' ~/.bashrc 2>/dev/null; then
                    echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc
                fi
                # Also add to zshrc for zsh users
                if ! grep -q '/usr/local/cuda/bin' ~/.zshrc 2>/dev/null; then
                    echo 'export PATH=/usr/local/cuda/bin:$PATH' >> ~/.zshrc
                fi
                if ! grep -q '/usr/local/cuda/lib64' ~/.zshrc 2>/dev/null; then
                    echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> ~/.zshrc
                fi
            else
                echo "Failed to download NVIDIA cuda-keyring; skipping CUDA installation."
            fi
        else
            echo "CUDA toolkit is already installed."
        fi
    else
        echo "No NVIDIA GPU detected. Skipping NVIDIA toolkit installation."
    fi

    # Install Docker from official repo
    docker_setup

    # Change default shell to zsh
    if [ "$SHELL" != "$(which zsh)" ]; then
        sudo chsh -s "$(which zsh)" "$USER"
    fi

    # If repo has a preset Powerlevel10k config, install it
    if [ -f "$REPO_DIR/.p10k.zsh" ]; then
        cp "$REPO_DIR/.p10k.zsh" "$HOME/.p10k.zsh"
    fi

    # Ensure ZSH uses Powerlevel10k theme
    if grep -q '^ZSH_THEME=' "$HOME/.zshrc"; then
        sed -i 's|^ZSH_THEME=.*|ZSH_THEME="powerlevel10k/powerlevel10k"|' "$HOME/.zshrc"
    else
        echo 'ZSH_THEME="powerlevel10k/powerlevel10k"' >> "$HOME/.zshrc"
    fi

    # Ensure .zshrc sources the Powerlevel10k config if present
    if ! grep -q 'source ~/.p10k.zsh' "$HOME/.zshrc"; then
        echo '[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh' >> "$HOME/.zshrc"
    fi

### macOS ###
elif [[ "$OSTYPE" == "darwin"* ]]; then
    # Update all macOS Software via the command line
    softwareupdate --install -a || true
    
    # Install Xcode Command Line Tools
    if ! xcode-select -p &>/dev/null; then
        xcode-select --install
    fi

    # Install Homebrew
    touch ~/.hushlogin
    if ! [ -x "$(command -v brew)" ]; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"    
    fi
    
    ### Apple Silicon ###
    if [[ $(uname -m) == 'arm64' ]]; then
        # Make sure native Homebrew for ARM is in path
        if ! grep -q '/opt/homebrew/bin/brew shellenv' ~/.zprofile 2>/dev/null; then
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
        fi
		
		### Install Rosetta 2 ###
		if ! arch -x86_64 /usr/bin/true 2>/dev/null; then
			softwareupdate --install-rosetta --agree-to-license
		fi

		### Copy helper scripts (MLX tools, etc.) ###
		if [ -d "$REPO_DIR/bin" ]; then
			mkdir -p "$HOME/bin"
			cp -r "$REPO_DIR/bin/"* "$HOME/bin/"
			chmod +x "$HOME/bin/"*
			echo "Copied helper scripts from bin/ to ~/bin/"
		fi

		### Ghostty terminal config ###
		if [ -f "$REPO_DIR/ghostty_config" ]; then
			mkdir -p "$HOME/Library/Application Support/com.mitchellh.ghostty"
			cp "$REPO_DIR/ghostty_config" "$HOME/Library/Application Support/com.mitchellh.ghostty/config"
			echo "Installed Ghostty config"
		fi
	### End Apple Silicon ###

    ### Intel ###
	# NOTE: This option is DEPRECATED; I don't see myself using an Intel Mac anywhere in the near future
    elif [[ $(uname -m) == 'x86_64' ]]; then
        echo "Intel macOS path is deprecated; skipping Anaconda download here."
    fi
	### End Intel ###

    # TODO: Where is Apple Silicon Anaconda??

    configure_ssh_key

    # Install Oh My Zsh and Powerlevel10k
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    fi
    if [ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k" ]; then
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k
    fi
    plugins=(zsh-autosuggestions zsh-syntax-highlighting)
    for plugin in "${plugins[@]}"; do
        if [ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/$plugin" ]; then
            git clone https://github.com/zsh-users/$plugin ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/$plugin
        fi
    done
    brew tap homebrew/cask-fonts 2>/dev/null || true
    brew install --cask font-meslo-lg-nerd-font 2>/dev/null || true

    # Company Laptop Setup (Assume Apple Silicon Only)
    if [ "$level" -eq 2 ]; then
        # Prompt me for company Git link
        echo "Please enter the company Git link: "
        read company_git
        
        if [ -n "$company_git" ]; then
            if [ ! -d "company_private_setup" ]; then
                git clone --recurse-submodules "$company_git" company_private_setup
            fi
            cd company_private_setup
            ./setup_private.sh
            cd ..  
        fi    
    fi

    # Zinit plugin manager
    if [ ! -d "$HOME/.local/share/zinit" ]; then
        bash -c "$(curl --fail --show-error --silent --location https://raw.githubusercontent.com/zdharma-continuum/zinit/HEAD/scripts/install.sh)" -y
    fi

    brew install $(cat Brewfile)
    brew install --cask ghostty 2>/dev/null || true

    # XCODE RELATED THIHGS
    ### If you're on a beta, you need to switch the path
    # sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer

    # lscpu for macOS
    if ! grep -q 'alias lscpu=' ~/.zshrc 2>/dev/null; then
        echo 'alias lscpu="sysctl -a"' >> ~/.zshrc
    fi
else
    echo "Unknown OS type: $OSTYPE" >&2
    exit 1
fi

git_setup
ssh_config_setup

if [ "$school" -eq 1 ]; then
    mkdir -p dev
    mkdir -p dev/school
    cd dev/school
    [ ! -d "cs61a" ] && git clone --recurse git@github.com:briancpark/cs61a.git cs61a || true
    [ ! -d "cs61bl" ] && git clone --recurse git@github.com:briancpark/cs61bl.git cs61bl || true
    [ ! -d "cs61c" ] && git clone --recurse git@github.com:briancpark/cs61c.git cs61c || true
    [ ! -d "cs70" ] && git clone --recurse git@github.com:briancpark/cs70.git cs70 || true
    [ ! -d "eecs16a" ] && git clone --recurse git@github.com:briancpark/eecs16a.git eecs16a || true
    [ ! -d "eecs16b" ] && git clone --recurse git@github.com:briancpark/eecs16b.git eecs16b || true
    [ ! -d "ds100" ] && git clone --recurse git@github.com:briancpark/ds100.git ds100 || true
    [ ! -d "cs152" ] && git clone --shallow-submodules git@github.com:briancpark/cs152.git cs152 || true
    [ ! -d "cs161" ] && git clone --recurse git@github.com:briancpark/cs161.git cs161 || true
    [ ! -d "cs162" ] && git clone --recurse git@github.com:briancpark/cs162.git cs162 || true
    [ ! -d "cs170" ] && git clone --recurse git@github.com:briancpark/cs170.git cs170 || true
    [ ! -d "cs188" ] && git clone --recurse git@github.com:briancpark/cs188.git cs188 || true
    [ ! -d "cs189" ] && git clone --recurse git@github.com:briancpark/cs189.git cs189 || true
    [ ! -d "cs267" ] && git clone --recurse git@github.com:briancpark/cs267.git cs267 || true
    [ ! -d "csc512" ] && git clone --recurse git@github.com:briancpark/csc512.git csc512 || true
    [ ! -d "csc542" ] && git clone --recurse git@github.com:briancpark/csc542.git csc542 || true
    [ ! -d "csc561" ] && git clone --recurse git@github.com:briancpark/csc561.git csc561 || true
    [ ! -d "csc591-007" ] && git clone --recurse git@github.com:briancpark/csc591-007.git csc591-007 || true
    [ ! -d "csc591-026" ] && git clone --recurse git@github.com:briancpark/csc591-026.git csc591-026 || true
    [ ! -d "csc791-025" ] && git clone --recurse git@github.com:briancpark/csc791-025.git csc791-025 || true
    [ ! -d "csc766" ] && git clone --recurse git@github.com:briancpark/csc766.git csc766 || true
    [ ! -d "ece786" ] && git clone --recurse git@github.com:briancpark/ece786.git ece786 || true
    cd ../..
fi

conda_setup
vim_setup

# Tailscale — every machine
tailscale_setup

# AI coding assistants (Claude Code, Codex, Antigravity) — personal machines only
if [ "$level" -eq 1 ]; then
    ai_tools_setup
fi