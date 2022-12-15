#!/bin/bash

# Install OS-specific packages

if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    sudo apt install python3 python3-pip default-jre gcc valgrind neofetch htop vim git texlive-full libgl1-mesa-glx libegl1-mesa libxrandr2 libxrandr2 libxss1 libxcursor1 libxcomposite1 libasound2 libxi6 libxtst6 texlive-fonts-extra xclip tmux vlc nmap snap -y    
    
    # External installations
    wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    sudo apt install ./google-chrome-stable_current_amd64.deb
    rm google-chrome-stable_current_amd64.deb

    # Anaconda configuration
    wget -O - https://www.anaconda.com/distribution/ 2>/dev/null | sed -ne 's@.*\(https:\/\/repo\.anaconda\.com\/archive\/Anaconda3-.*-Linux-x86_64\.sh\)\">64-Bit (x86) Installer.*@\1@p' | xargs wget
    

    # Other installation
    sudo snap install --classic code 
    sudo snap install --classic heroku
elif [[ "$OSTYPE" == "darwin"* ]]; then
    # Install Homebrew
    if ! [ -x "$(command -v brew)" ]; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"    
    fi
    

    # Apple Silicon
    if [[ $(uname -m) == 'arm64' ]]; then
        true
    # Intel
    elif [[ $(uname -m) == 'x86_64' ]]; then
        wget -O - https://www.anaconda.com/distribution/ 2>/dev/null | sed -ne 's@.*\(https:\/\/repo\.anaconda\.com\/archive\/Anaconda3-.*-Linux-MacOS\.sh\)\">64-Bit (x86) Installer.*@\1@p' | xargs wget
    fi

    brew install vim git gcc valgrind neofetch htop tmux vlc nmap vagrant golangci-lint clang-format wget cmake
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

# Git configuration
git config --global user.name "Brian Park"
git config --global user.email bcpark@ncsu.edu
git config --global core.editor vim

# Clone UC Berkeley Repositories
git clone --recurse git@github.com:briancpark/cs61a.git cs61a
git clone --recurse git@github.com:briancpark/cs61bl.git cs61bl
git clone --recurse git@github.com:briancpark/cs61c.git cs61c
git clone --recurse git@github.com:briancpark/cs70.git cs70
git clone --recurse git@github.com:briancpark/eecs16a.git eecs16a
git clone --recurse git@github.com:briancpark/eecs16b.git eecs16b
git clone --recurse git@github.com:briancpark/ds100.git ds100
git clone git@github.com:briancpark/cs152.git cs152 # TODO: Some submodules for this repo are broken
git clone --recurse git@github.com:briancpark/cs161.git cs161
git clone --recurse git@github.com:briancpark/cs162.git cs162
git clone --recurse git@github.com:briancpark/cs170.git cs170
git clone --recurse git@github.com:briancpark/cs188.git cs188
git clone --recurse git@github.com:briancpark/cs189.git cs189
git clone --recurse git@github.com:briancpark/cs267.git cs267

# Clone NCSU Repositories
git clone --recurse git@github.com:briancpark/csc512.git
git clone --recurse git@github.com:briancpark/csc591-007.git
git clone --recurse git@github.com:briancpark/csc791-025.git

git clone git@github.com:briancpark/vim.git
cp vim/vimrc ./
mv vimrc .vimrc
rm -rf vim


# Install Anaconda
bash Anaconda3*.sh
rm Anaconda3*.sh
export PATH="~/anaconda3/bin:$PATH"

conda config --set auto_activate_base false

conda create -n cs61a python=3.6 -y
conda create -n cs61bl python=3.9 -y
conda create -n cs61c python=3.6 -y
conda create -n cs170 python=3.9 -y
conda create -n cs188 python=3.6 -y
conda create -n cs189 python=3.8.5 -y
conda create -n eecs16a python=3.8 -y
conda create -n eecs16b python=3.8 -y

conda create -n csc591 python=3.8 -y
conda create -n csc791 python=3.10 -y

conda create -n nums python=3.7 -y

cd ds100
conda env create -f data100_environment.yml
cd ../cs189
pip3 install -r requirements.txt


