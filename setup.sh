#!/bin/bash

# Apt installations
sudo apt install python3 python3-pip default-jre gcc valgrind neofetch htop vim git texlive-full libgl1-mesa-glx libegl1-mesa libxrandr2 libxrandr2 libxss1 libxcursor1 libxcomposite1 libasound2 libxi6 libxtst6 texlive-fonts-extra xclip tmux vlc nmap snap -y

# External installations
wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
sudo apt install ./google-chrome-stable_current_amd64.deb
rm google-chrome-stable_current_amd64.deb

# Git configuration
#ssh-keygen -t ed25519 -C "briancpark@berkeley.edu"
#eval "$(ssh-agent -s)"
#ssh-add ~/.ssh/id_ed25519
#xclip -selection clipboard < ~/.ssh/id_ed25519.pub

git config --global user.name "Brian Park"
git config --global user.email briancpark@berkeley.edu
git config --global core.editor vim

git clone --recurse git@github.com:briancpark/cs61a.git cs61a
git clone --recurse git@github.com:briancpark/cs61bl.git cs61bl
git clone --recurse git@github.com:briancpark/cs61c.git cs61c
git clone --recurse git@github.com:briancpark/cs70.git cs70
git clone --recurse git@github.com:briancpark/eecs16a.git eecs16a
git clone --recurse git@github.com:briancpark/eecs16b.git eecs16b
git clone --recurse git@github.com:briancpark/ds100.git ds100
git clone --recurse git@github.com:briancpark/cs170.git cs170/hw
git clone --recurse git@github.com:briancpark/cs170-project.git cs170/proj
git clone --recurse git@github.com:briancpark/cs188.git cs188
git clone --recurse git@github.com:briancpark/cs189.git cs189
git clone --recurse git@github.com:briancpark/cs161.git cs161
git clone --recurse git@github.com:briancpark/cs162.git cs162/hw
git clone --recurse git@github.com:briancpark/pintos.git cs162/proj
git clone git@github.com:briancpark/cs152.git cs152
git clone --recurse git@github.com:briancpark/cs267.git cs267


git clone git@github.com:briancpark/vim.git
cp vim/vimrc ./
mv vimrc .vimrc
rm -rf vim

# Anaconda configuration
wget -O - https://www.anaconda.com/distribution/ 2>/dev/null | sed -ne 's@.*\(https:\/\/repo\.anaconda\.com\/archive\/Anaconda3-.*-Linux-x86_64\.sh\)\">64-Bit (x86) Installer.*@\1@p' | xargs wget
bash Anaconda3-2021.05-Linux-x86_64.sh

export PATH="~/anaconda3/bin:$PATH"

conda config --set auto_activate_base false

conda create -n cs61a python=3.6
conda create -n cs61bl python=3.9
conda create -n cs61c python=3.6
conda create -n cs170 python=3.9
conda create -n cs188 python=3.6
conda create -n cs189 python=3.8.5
conda create -n eecs16a python=3.8
conda create -n eecs16b python=3.8

conda create -n nums python=3.7

cd ds100
conda env create -f data100_environment.yml
cd ../cs189
pip3 install -r requirements.txt

# Other installation
sudo snap install --classic code 
sudo snap install --classic heroku
