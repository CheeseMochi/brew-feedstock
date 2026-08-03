#!/bin/bash

# Clean up Homebrew environment variables
unset HOMEBREW_PREFIX
unset HOMEBREW_CELLAR
unset HOMEBREW_REPOSITORY
unset HOMEBREW_LIBRARY
unset HOMEBREW_USER_CONFIG_HOME
unset HOMEBREW_BREW_GIT_REMOTE
unset HOMEBREW_CORE_DEFAULT_GIT_REMOTE
unset HOMEBREW_NO_AUTO_UPDATE
unset HOMEBREW_NO_ANALYTICS
unset _BREW_COMPLETION_LOADED

# Remove $CONDA_PREFIX/homebrew/{bin,sbin} from PATH and squeeze any resulting "::"
export PATH="$(echo "$PATH" | sed \
    -e "s|${CONDA_PREFIX:-/opt/conda}/homebrew/bin:||g" \
    -e "s|${CONDA_PREFIX:-/opt/conda}/homebrew/sbin:||g" \
    -e 's/::/:/g')"

# Fish: Remove completion path
if [ -n "${FISH_VERSION:-}" ]; then
  if [ -n "${fish_complete_path:-}" ]; then
    new_path=""
    for p in ${fish_complete_path}; do
      case "$p" in
        "${CONDA_PREFIX:-/opt/conda}/homebrew/share/fish/completions") ;;
        *)
          if [ -z "$new_path" ]; then
            new_path="$p"
          else
            new_path="${new_path}:${p}"
          fi
          ;;
      esac
    done
    set -g fish_complete_path "${new_path}"
  fi
fi
