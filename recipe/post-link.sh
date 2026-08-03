#!/bin/bash

# post-link.sh runs once after the package is linked into an environment.
# We run brew doctor to validate the installation.
#
# NOTE: conda link scripts get $PREFIX (the env being linked into), not
# $CONDA_PREFIX -- that's only set during activation, and is NOT guaranteed
# to be set (or correct) at link time. Using CONDA_PREFIX here silently
# turns every path below into a filesystem-root path, which is exactly the
# kind of failure `|| true` hides -- don't reintroduce it.

# Ensure brew is on PATH for this script (bin+sbin, matching brew-activate.sh,
# so `brew doctor` below doesn't warn about sbin being missing from PATH)
PATH="${PREFIX}/homebrew/bin:${PREFIX}/homebrew/sbin:${PATH}"
export HOMEBREW_PREFIX="${PREFIX}/homebrew"
export HOMEBREW_CELLAR="${PREFIX}/homebrew/Cellar"
export HOMEBREW_REPOSITORY="${PREFIX}/homebrew"
export HOMEBREW_LIBRARY="${PREFIX}/homebrew/Library"

# post-link runs before any activate.d hook, so this is the only place these
# get set for this one-off `brew doctor` call.
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ANALYTICS=1

# Create required directories to prevent first-run issues
mkdir -p "${PREFIX}/homebrew/Cellar"
mkdir -p "${PREFIX}/homebrew/opt"
mkdir -p "${PREFIX}/homebrew/var/homebrew/Cache"
mkdir -p "${PREFIX}/homebrew/var/homebrew/linked"

# Run brew doctor so warnings don't block installation (a conda-scoped
# install will legitimately trigger some of its checks)
"${PREFIX}/homebrew/bin/brew" doctor 2>&1 || true
