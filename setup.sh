sudo apt install python3 default-jre gcc valgrind neofetch htop vim git texlive-full libgl1-mesa-glx libegl1-mesa libxrandr2 libxrandr2 libxss1 libxcursor1 libxcomposite1 libasound2 libxi6 libxtst6 texlive-fonts-extra -y

git clone git@github.com:briancpark/cs61a.git cs61a
git clone git@github.com:Berkeley-CS61B-Student/su20-540491-g6.git cs61bl/archive
git clone git@github.com:Berkeley-CS61B-Student/su20-p329.git cs61bl/shared
git clone git@github.com:Berkeley-CS61B-Student/su20-s98.git cs61bl/private
git clone git@github.com:briancpark/cs70.git cs70
git clone git@github.com:61c-student/fa20-lab-briancpark.git cs61c/lab
git clone git@github.com:61c-student/fa20-proj1-briancpark.git cs61c/proj1
git clone git@github.com:61c-student/fa20-proj2-borastan.git cs61c/proj2
git clone git@github.com:61c-student/fa20-proj3-borastan.git cs61c/proj3
git clone git@github.com:61c-student/fa20-proj4-cython.git cs61c/proj4
git clone git@github.com:briancpark/cs61c-toolchain.git cs61c/tools
git clone git@github.com:briancpark/eecs16a.git eecs16a
git clone git@github.com:briancpark/eecs16b.git eecs16b
git clone git@github.com:briancpark/ds100.git ds100
git clone git@github.com:briancpark/cs170.git cs170/hw
git clone git@github.com:briancpark/cs170-project.git cs170/proj
git clone git@github.com:briancpark/cs188.git cs188
git clone git@github.com:briancpark/cs189.git cs189

git clone git@github.com:briancpark/vim.git
cp vim/vimrc ./
mv vimrc .vimrc

wget https://repo.anaconda.com/archive/Anaconda3-2021.05-Linux-x86_64.sh
bash Anaconda3-2021.05-Linux-x86_64.sh

export PATH="~/anaconda3/bin:$PATH"

conda config --set auto_activate_base false

conda create -n cs61a python=3.8
conda create -n cs61bl python=3.9
conda create -n cs61c python=3.6
conda create -n cs170 python=3.8
conda create -n cs188 python=3.6
conda create -n cs189 python=3.8.5

cd ds100
conda env create -f data100_environment.yml

cd ../cs189
pip3 install -r requirements.txt


