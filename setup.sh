#!/bin/bash

###############
# CLI Arguments
###############

school=0

# Check for --school option
for arg in "$@"
do
    case $arg in
        --school)
        school=1
        shift # Remove --school from processing
        ;;
        *)
        shift # Remove generic argument from processing
        ;;
    esac
done

###############
# Setup Script
###############

# We start and install everything in the home directory
cd $HOME

# Install OS-specific packages

### LINUX ###
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    sudo apt install \
        python3 \
        python3-pip \
        default-jre \
        gcc \
        valgrind \
        neofetch \
        htop \
        vim \
        git \
        texlive-full \
        libgl1-mesa-glx \
        libegl1-mesa \
        libxrandr2 \
        libxrandr2 \
        libxss1 \
        libxcursor1 \
        libxcomposite1 \
        libasound2 \
        libxi6 \
        libxtst6 \
        texlive-fonts-extra \
        xclip \
        tmux \
        vlc \
        nmap \
        snap \
        -y    
    
    ### External Installations ###
    # Google Chrome
    wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    sudo apt install ./google-chrome-stable_current_amd64.deb
    rm google-chrome-stable_current_amd64.deb

    # Anaconda 
    wget -O - https://www.anaconda.com/distribution/ 2>/dev/null | sed -ne 's@.*\(https:\/\/repo\.anaconda\.com\/archive\/Anaconda3-.*-Linux-x86_64\.sh\)\">64-Bit (x86) Installer.*@\1@p' | xargs wget
    
    # Other installation
    sudo snap install --classic code 
    sudo snap install --classic heroku

### MAC OS ###
elif [[ "$OSTYPE" == "darwin"* ]]; then
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
        wget -O - https://www.anaconda.com/distribution/ 2>/dev/null | sed -ne 's@.*\(https:\/\/repo\.anaconda\.com\/archive\/Anaconda3-.*-Linux-MacOS\.sh\)\">64-Bit (x86) Installer.*@\1@p' | xargs wget
    fi
	### End Intel ###

	sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

    brew install \
        vim \
        git \
        gcc \
        valgrind \
        neofetch \
        htop \
        tmux \
        vlc \
        nmap \
        vagrant \
        golangci-lint \
        clang-format \
        wget \
        cmake \
        asitop \
	    mactop    
else
    error "Unknown OS type: $OSTYPE"
fi

# SSH key configuration
if ! [ -f ~/.ssh/id_ed25519.pub ]; then
    ssh-keygen -t ed25519 -C "bcpark@ncsu.edu"
    eval "$(ssh-agent -s)"
    ssh-add ~/.ssh/id_ed25519
    cat ~/.ssh/id_ed25519.pub
    echo "Please add the above SSH key to your GitHub account."
    read response
fi


### Git Repositories ###
git config --global user.name "Brian Park"
git config --global user.email me@briancpark.com
git config --global core.editor vim

if [ "$school" -eq 1 ]; then
    git clone --recurse git@github.com:briancpark/cs61a.git cs61a
    git clone --recurse git@github.com:briancpark/cs61bl.git cs61bl
    git clone --recurse git@github.com:briancpark/cs61c.git cs61c
    git clone --recurse git@github.com:briancpark/cs70.git cs70
    git clone --recurse git@github.com:briancpark/eecs16a.git eecs16a
    git clone --recurse git@github.com:briancpark/eecs16b.git eecs16b
    git clone --recurse git@github.com:briancpark/ds100.git ds100
    git clone git@github.com:briancpark/cs152.git cs152
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
fi

# Install Anaconda
bash Anaconda3*.sh
rm Anaconda3*.sh
export PATH="~/anaconda3/bin:$PATH"

conda config --set auto_activate_base false

if [ "$school" -eq 1 ]; then
    conda create -n cs61a python=3.6 -y
    conda create -n cs61bl python=3.9 -y
    conda create -n cs61c python=3.6 -y
    conda create -n cs170 python=3.9 -y
    conda create -n cs188 python=3.6 -y
    conda create -n cs189 python=3.8.5 -y
    conda create -n eecs16a python=3.8 -y
    conda create -n eecs16b python=3.8 -y

    conda create -n csc542 python=3.10 -y
    conda create -n csc591 python=3.8 -y
    conda create -n csc791 python=3.10 -y

    conda create -n nums python=3.7 -y
fi


### Vim Configuration ###
git clone https://github.com/powerline/fonts
cd fonts
./install.sh

# Vim Configuration
git clone git@github.com:briancpark/vim.git
cp vim/vimrc ./
mv vimrc .vimrc
rm -rf vim

git clone https://github.com/github/copilot.vim \
   ~/.vim/pack/github/start/copilot.vim

curl -fLo ~/.vim/autoload/plug.vim --create-dirs https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
