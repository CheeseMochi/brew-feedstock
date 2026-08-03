#!/bin/bash

# Insert $CONDA_PREFIX/homebrew/{bin,sbin} right after $CONDA_PREFIX/bin in
# PATH (same bin+sbin exposure `brew shellenv` does upstream — omitting sbin
# makes `brew doctor` warn about sbin-installing formulae not being on PATH).
# Search for $CONDA_PREFIX/bin anywhere in PATH rather than assuming it's the
# literal first entry: that assumption holds for a typical single `conda
# activate`, but not for every activation context (e.g. conda-build's own
# package test harness activates a test env from inside an already-active
# build env), and silently no-op'ing here left homebrew/bin off PATH entirely.
_brew_bin="${CONDA_PREFIX:-/opt/conda}/bin"
_brew_homebrew_bin="${CONDA_PREFIX:-/opt/conda}/homebrew/bin"
_brew_homebrew_sbin="${CONDA_PREFIX:-/opt/conda}/homebrew/sbin"
case ":${PATH}:" in
    *":${_brew_homebrew_bin}:"*)
        ;; # already present (e.g. re-activation) -- don't insert again
    *":${_brew_bin}:"*)
        # Split PATH right after the first "$_brew_bin:" occurrence and splice
        # homebrew bin/sbin into the gap. Avoids ${var/pat/repl}, whose quoting
        # rules get unreliable once this script is captured as a string and
        # re-parsed via `eval` (as conda's activation machinery, and this
        # project's own tests, both do).
        _brew_after="${PATH#*"${_brew_bin}:"}"
        _brew_before="${PATH%"${_brew_after}"}"
        export PATH="${_brew_before}${_brew_homebrew_bin}:${_brew_homebrew_sbin}:${_brew_after}"
        unset _brew_after _brew_before
        ;;
    *)
        # $CONDA_PREFIX/bin isn't in PATH at all (unexpected) -- prepend
        export PATH="${_brew_bin}:${_brew_homebrew_bin}:${_brew_homebrew_sbin}:${PATH}"
        ;;
esac
unset _brew_bin _brew_homebrew_bin _brew_homebrew_sbin

# Homebrew computes its prefix from the binary location, so we set
# the remaining environment variables for consistency.
export HOMEBREW_PREFIX="${CONDA_PREFIX}/homebrew"
export HOMEBREW_CELLAR="${CONDA_PREFIX}/homebrew/Cellar"
export HOMEBREW_REPOSITORY="${CONDA_PREFIX}/homebrew"
export HOMEBREW_LIBRARY="${CONDA_PREFIX}/homebrew/Library"

# Keep Homebrew config inside the conda env, not in user's home
export HOMEBREW_USER_CONFIG_HOME="${CONDA_PREFIX}/homebrew"

# Disable auto-update (we ship a specific version)
export HOMEBREW_NO_AUTO_UPDATE=1

# Disable analytics (conda envs are often ephemeral)
export HOMEBREW_NO_ANALYTICS=1

# --- Shell Completion Setup ---

# Zsh: Source the brew completion file directly (only once per shell)
if [ -n "${ZSH_VERSION:-}" ]; then
  if [ "${_BREW_COMPLETION_LOADED:-}" != "1" ] && \
     [ -f "${CONDA_PREFIX}/homebrew/share/zsh/site-functions/brew" ]; then
    source "${CONDA_PREFIX}/homebrew/share/zsh/site-functions/brew" 2>/dev/null
    export _BREW_COMPLETION_LOADED="1"
  fi
fi

# Fish: Add completion path
if [ -n "${FISH_VERSION:-}" ]; then
  if [ -f "${CONDA_PREFIX}/homebrew/share/fish/completions/brew.fish" ]; then
    set -p fish_complete_path "${CONDA_PREFIX}/homebrew/share/fish/completions"
  fi
fi

# Bash: Source the completion file directly
if [ -n "${BASH_VERSION:-}" ]; then
  if [ -f "${CONDA_PREFIX}/homebrew/share/bash_completion.d/brew.sh" ]; then
    source "${CONDA_PREFIX}/homebrew/share/bash_completion.d/brew.sh" 2>/dev/null || true
  fi
fi
