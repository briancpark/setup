# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# If you come from bash you might have to change your $PATH.
# export PATH=$HOME/bin:/usr/local/bin:$PATH

# Path to your oh-my-zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Set name of the theme to load --- if set to "random", it will
# load a random theme each time oh-my-zsh is loaded, in which case,
# to know which specific one was loaded, run: echo $RANDOM_THEME
# See https://github.com/ohmyzsh/ohmyzsh/wiki/Themes
ZSH_THEME="powerlevel10k/powerlevel10k"

# Set list of themes to pick from when loading at random
# Setting this variable when ZSH_THEME=random will cause zsh to load
# a theme from this variable instead of looking in $ZSH/themes/
# If set to an empty array, this variable will have no effect.
# ZSH_THEME_RANDOM_CANDIDATES=( "robbyrussell" "agnoster" )

# Uncomment the following line to use case-sensitive completion.
# CASE_SENSITIVE="true"

# Uncomment the following line to use hyphen-insensitive completion.
# Case-sensitive completion must be off. _ and - will be interchangeable.
# HYPHEN_INSENSITIVE="true"

# Uncomment one of the following lines to change the auto-update behavior
# zstyle ':omz:update' mode disabled  # disable automatic updates
zstyle ':omz:update' mode auto      # update automatically without asking
# zstyle ':omz:update' mode reminder  # just remind me to update when it's time

# Uncomment the following line to change how often to auto-update (in days).
# zstyle ':omz:update' frequency 13

# Uncomment the following line if pasting URLs and other text is messed up.
# DISABLE_MAGIC_FUNCTIONS="true"

# Uncomment the following line to disable colors in ls.
# DISABLE_LS_COLORS="true"

# Uncomment the following line to disable auto-setting terminal title.
# DISABLE_AUTO_TITLE="true"

# Uncomment the following line to enable command auto-correction.
# ENABLE_CORRECTION="true"

# Uncomment the following line to display red dots whilst waiting for completion.
# You can also set it to another string to have that shown instead of the default red dots.
# e.g. COMPLETION_WAITING_DOTS="%F{yellow}waiting...%f"
# Caution: this setting can cause issues with multiline prompts in zsh < 5.7.1 (see #5765)
# COMPLETION_WAITING_DOTS="true"

# Uncomment the following line if you want to disable marking untracked files
# under VCS as dirty. This makes repository status check for large repositories
# much, much faster.
# DISABLE_UNTRACKED_FILES_DIRTY="true"

# Uncomment the following line if you want to change the command execution time
# stamp shown in the history command output.
# You can set one of the optional three formats:
# "mm/dd/yyyy"|"dd.mm.yyyy"|"yyyy-mm-dd"
# or set a custom format using the strftime function format specifications,
# see 'man strftime' for details.
# HIST_STAMPS="mm/dd/yyyy"

# Would you like to use another custom folder than $ZSH/custom?
# ZSH_CUSTOM=/path/to/new-custom-folder

# Which plugins would you like to load?
# Standard plugins can be found in $ZSH/plugins/
# Custom plugins may be added to $ZSH_CUSTOM/plugins/
# Example format: plugins=(rails git textmate ruby lighthouse)
# Add wisely, as too many plugins slow down shell startup.
plugins=(
  sudo
  git
  python
  virtualenv
  bundler
  dotenv
  macos
  rake
  rbenv
  ruby
  zsh-autosuggestions
  zsh-syntax-highlighting
)

source $ZSH/oh-my-zsh.sh

########### BEGIN CONFIG ###############

function setup_git_config() {
  local repo_name
  repo_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" || echo "Not in a Git repository")
  
  git config user.name "Brian Park"
  git config user.email "me@briancpark.com"
  git config commit.gpgsign false
  
  if [[ $repo_name == "Not in a Git repository" ]]; then
    echo "Git configuration updated! (No Git repository detected)"
  else
    echo "Git configuration updated for local repository: $repo_name"
  fi
}

function update_repos() {
    # Set the base directory
    BASE_DIR="$HOME/dev"

    # Navigate to the base directory
    cd $BASE_DIR || { echo "Directory not found: $BASE_DIR"; return 1; }

    # Loop through each directory in the base directory
    for repo in */; do
        if [ -d "$repo/.git" ]; then
            cd "$repo" || continue
            echo "Updating repository: $repo"

            # Fetch all branches
            git fetch --all

            # Check if the main branch exists and pull from it
            if git show-ref --verify --quiet refs/heads/main; then
                git checkout main
                git pull origin main
            # Otherwise, check if the master branch exists and pull from it
            elif git show-ref --verify --quiet refs/heads/master; then
                git checkout master
                git pull origin master
            else
                echo "No main or master branch found in $repo"
            fi

            # Navigate back to the base directory
            cd "$BASE_DIR" || return 1
        else
            echo "$repo is not a git repository"
        fi
    done

    echo "All repositories updated."
}

function lint() {
    if [ -f ".clang-format" ]; then
        for file in "$@"; do
            if [[ $file == *.c || $file == *.cpp || $file == *.h || $file == *.hpp ]]; then
                clang-format -i "$file" >/dev/null 2>&1
            fi
        done
    else
        cppcheck "$@" >/dev/null 2>&1
    fi
}

alias benchmark="sudo pmset -c"

# Run on Performance Cores
alias pcore="taskpolicy -c utility $1"

# Run on Efficiency Cores
alias ecore="taskpolicy -c background $1"

# Switch between ARM and Rosetta
alias arm="arch -arm64 zsh"
alias rosetta="arch -x86_64 zsh"

alias f="find . -name "

# .zsh_history
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_SAVE_NO_DUPS
export HISTIGNORE="ls:exit"


plugins=(git zsh-autosuggestions zsh-syntax-highlighting fast-syntax-highlighting zsh-autocomplete sudo web-search copyfile fzf)