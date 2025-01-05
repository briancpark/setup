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

# .zsh_history
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_SAVE_NO_DUPS
export HISTIGNORE="ls:exit"
