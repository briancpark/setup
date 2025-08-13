#!/bin/bash
set -euo pipefail

###############
# CLI Arguments
###############

# Initialize our own variables
school=0
level=0

if [ "$#" -eq 0 ]; then
    echo "No arguments provided. Please provide an argument."
    echo "Examples: --personal, --company, --remote, --embedded, optionally with --school"
    exit 1
fi

# Robust option parsing
while [[ $# -gt 0 ]]; do
    case "$1" in
        --school)
            school=1
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
    if [ ! -d "$HOME/vim" ]; then
        git clone https://github.com/briancpark/vim.git "$HOME/vim"
    fi
    if [ -f "$HOME/vim/vimrc" ]; then
        cp "$HOME/vim/vimrc" "$HOME/.vimrc"
    fi
    rm -rf "$HOME/vim"

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
    conda config --set auto_activate_base false || true

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


###############
# Setup Script
###############

# We start and install everything in the home directory
cd $HOME

# Install OS-specific packages

### Linux ###
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    sudo apt update
    if [ -f Aptfile ]; then
        # Install packages from Aptfile (idempotent)
        sudo xargs -a Aptfile apt install -y
    else
        echo "No Aptfile found. Skipping bulk apt installs."
    fi
    
    # Install Oh My Zsh and Powerlevel10k
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    fi
    sudo chsh -s $(which zsh)
    cp .zshrc "$HOME/.zshrc"

    if [ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k" ]; then
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k
    fi
    plugins=(zsh-autosuggestions zsh-syntax-highlighting)
    for plugin in "${plugins[@]}"; do
        if [ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/$plugin" ]; then
            git clone https://github.com/zsh-users/$plugin ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/$plugin
        fi
    done
    mkdir -p "$HOME/.local/share/fonts"
    curl -fL --create-dirs -o "$HOME/.local/share/fonts/MesloLGS NF Regular.ttf" https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Regular.ttf
    curl -fL --create-dirs -o "$HOME/.local/share/fonts/MesloLGS NF Bold.ttf" https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold.ttf
    curl -fL --create-dirs -o "$HOME/.local/share/fonts/MesloLGS NF Italic.ttf" https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Italic.ttf
    curl -fL --create-dirs -o "$HOME/.local/share/fonts/MesloLGS NF Bold Italic.ttf" https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold%20Italic.ttf
    fc-cache -fv

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
        echo "NVIDIA GPU detected. Installing NVIDIA toolkit and developer packages..."
        arch=$(dpkg --print-architecture)
        ubuntu_ver=$(lsb_release -sr | cut -d. -f1)
        tmpdeb=/tmp/cuda-keyring.deb
        if curl -fL -o "$tmpdeb" "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${ubuntu_ver}/${arch}/cuda-keyring_1.1-1_all.deb"; then
            sudo dpkg -i "$tmpdeb"
            sudo apt update
            sudo apt install -y cuda-toolkit
            echo 'export PATH=/usr/local/cuda/bin:$PATH' >> ~/.bashrc
            echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc
        else
            echo "Failed to download NVIDIA cuda-keyring; skipping CUDA installation."
        fi
    else
        echo "No NVIDIA GPU detected. Skipping NVIDIA toolkit installation."
    fi

### macOS ###
elif [[ "$OSTYPE" == "darwin"* ]]; then
    # Update all macOS Software via the command line
    softwareupdate --install -a  
    
    # Install Xcode Command Line Tools
    xcode-select --install

    # Install Homebrew
    touch ~/.hushlogin
    if ! [ -x "$(command -v brew)" ]; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"    
    fi
    
    ### Apple Silicon ###
    if [[ $(uname -m) == 'arm64' ]]; then
        # Make sure native Homebrew for ARM is in path
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
		
		### Install Rosetta 2 ###
		softwareupdate --install-rosetta --agree-to-license
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
    brew tap homebrew/cask-fonts
    brew install --cask font-meslo-lg-nerd-font

    # Company Laptop Setup (Assume Apple Silicon Only)
    if [ "$level" -eq 2 ]; then
        # Prompt me for company Git link
        echo "Please enter the company Git link: "
        read company_git
        
        if [ -n "$company_git" ]; then
            git clone --recurse-submodules "$company_git" company_private_setup
            cd company_private_setup
            ./setup_private.sh
            cd ..  
        fi    
    fi

    # Zinit plugin manager
    bash -c "$(curl --fail --show-error --silent --location https://raw.githubusercontent.com/zdharma-continuum/zinit/HEAD/scripts/install.sh)" -y

    brew install $(cat Brewfile)
    
    # XCODE RELATED THIHGS
    ### If you're on a beta, you need to switch the path
    # sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer

    # lscpu for macOS
    echo 'alias lscpu="sysctl -a"' >> ~/.zshrc
else
    echo "Unknown OS type: $OSTYPE" >&2
    exit 1
fi

git_setup

if [ "$school" -eq 1 ]; then
    mkdir -p dev
    mkdir -p dev/school
    cd dev/school
    git clone --recurse git@github.com:briancpark/cs61a.git cs61a
    git clone --recurse git@github.com:briancpark/cs61bl.git cs61bl
    git clone --recurse git@github.com:briancpark/cs61c.git cs61c
    git clone --recurse git@github.com:briancpark/cs70.git cs70
    git clone --recurse git@github.com:briancpark/eecs16a.git eecs16a
    git clone --recurse git@github.com:briancpark/eecs16b.git eecs16b
    git clone --recurse git@github.com:briancpark/ds100.git ds100
    git clone --shallow-submodules git@github.com:briancpark/cs152.git cs152
    git clone --recurse git@github.com:briancpark/cs161.git cs161
    git clone --recurse git@github.com:briancpark/cs162.git cs162
    git clone --recurse git@github.com:briancpark/cs170.git cs170
    git clone --recurse git@github.com:briancpark/cs188.git cs188
    git clone --recurse git@github.com:briancpark/cs189.git cs189
    git clone --recurse git@github.com:briancpark/cs267.git cs267
    git clone --recurse git@github.com:briancpark/csc512.git csc512
    git clone --recurse git@github.com:briancpark/csc542.git csc542
    git clone --recurse git@github.com:briancpark/csc561.git csc561
    git clone --recurse git@github.com:briancpark/csc591-007.git csc591-007
    git clone --recurse git@github.com:briancpark/csc591-026.git csc591-026
    git clone --recurse git@github.com:briancpark/csc791-025.git csc791-025
    git clone --recurse git@github.com:briancpark/csc766.git csc766
    git clone --recurse git@github.com:briancpark/ece786.git ece786
    cd ../..
fi

conda_setup
vim_setup