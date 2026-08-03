#!/bin/bash
set -e

# Fetch the Homebrew source tarball
BREW_VERSION="5.1.11"
HOMEBREW_SRC="$SRC_DIR/brew-${BREW_VERSION}"

# Clone Homebrew if the tarball wasn't unpacked by conda-build. Pinned to the
# same tag as source.url/source.sha256 in meta.yaml — an unpinned clone would
# silently build against current master, which has diverged enough from
# 5.1.11 that the patch's hunks no longer apply cleanly against it.
if [ ! -d "$HOMEBREW_SRC" ]; then
  git clone --depth 1 --branch "$BREW_VERSION" https://github.com/Homebrew/brew.git "$HOMEBREW_SRC"
fi

# Create the homebrew directory inside the conda prefix
HOMEBREW_INSTALL_DIR="${PREFIX}/homebrew"
mkdir -p "${HOMEBREW_INSTALL_DIR}"

# Copy Homebrew into the prefix
cp -R "${HOMEBREW_SRC}/." "${HOMEBREW_INSTALL_DIR}"

# Remove ELF/Mach-O binary fixtures that break conda-build (patchelf/LIEF)
rm -rf "${HOMEBREW_INSTALL_DIR}/Library/Homebrew/test/support/fixtures/elf"
rm -rf "${HOMEBREW_INSTALL_DIR}/Library/Homebrew/test/support/fixtures/mach"
rm -rf "${HOMEBREW_INSTALL_DIR}/Library/Homebrew/test/support/fixtures/cask/NewApp.app/Contents/MacOS"

# Apply the conda-brew path rewrite patch to the copy that actually ships
# (not $SRC_DIR, which build.sh's cwd points at) — a failed patch must fail
# the build, not silently ship stock Homebrew. Default fuzz is intentional:
# --fuzz=0 was tried and rejected a hunk GNU patch otherwise locates correctly
# and unambiguously (verified byte-for-byte), due to an edge-context-trimming
# quirk in small hunks, not a real ambiguity risk. Relying on the `patch`
# build dep (real GNU patch, not macOS's ancient BSD one) plus this explicit
# exit-code check is what actually prevents silent failure.
if [ -f "${RECIPE_DIR}/conda-brew-path-rewrite.patch" ]; then
  if ! (cd "${HOMEBREW_INSTALL_DIR}" && patch -p1 --forward < "${RECIPE_DIR}/conda-brew-path-rewrite.patch"); then
    echo "Error: conda-brew-path-rewrite.patch failed to apply cleanly" >&2
    exit 1
  fi
fi

# Remove git repo to keep package small
rm -rf "${HOMEBREW_INSTALL_DIR}/.git"

# --- Generate brew.env with git remote config ---
# HOMEBREW_NO_AUTO_UPDATE/HOMEBREW_NO_ANALYTICS are also set by
# brew-activate.sh, but that only takes effect once the env is `conda
# activate`d. brew.env is read directly by bin/brew on every invocation
# (once HOMEBREW_PREFIX resolves correctly), so this is what actually stops
# `brew install` from running an implicit `brew update` -- which re-clones
# Homebrew's repo, undoing the .git removal above and every patched file,
# including this package's own path-rewrite patch.
mkdir -p "${HOMEBREW_INSTALL_DIR}/etc/homebrew"
cat > "${HOMEBREW_INSTALL_DIR}/etc/homebrew/brew.env" << 'BREW_ENV'
export HOMEBREW_BREW_GIT_REMOTE="https://github.com/Homebrew/brew.git"
export HOMEBREW_CORE_DEFAULT_GIT_REMOTE="https://github.com/Homebrew/homebrew-core.git"
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ANALYTICS=1
BREW_ENV

# --- Generate version.sh ---
# .git was just removed above, so this can't be detected from the tree; use
# the pinned version directly.
cat > "${HOMEBREW_INSTALL_DIR}/etc/homebrew/version.sh" << VERSION_SH
export HOMEBREW_VERSION="${BREW_VERSION}"
VERSION_SH

# --- Ensure completion directories exist ---
mkdir -p "${HOMEBREW_INSTALL_DIR}/share/zsh/site-functions"
mkdir -p "${HOMEBREW_INSTALL_DIR}/share/fish/completions"
mkdir -p "${HOMEBREW_INSTALL_DIR}/share/bash_completion.d"
mkdir -p "${HOMEBREW_INSTALL_DIR}/Library/Taps"

# --- Install conda activate/deactivate hooks ---
# These live in the recipe under recipe/etc/conda/{de,}activate.d/ but conda
# only runs them if they're actually present under $PREFIX/etc/conda/ in the
# built package -- nothing does that automatically, they must be copied in.
mkdir -p "${PREFIX}/etc/conda/activate.d" "${PREFIX}/etc/conda/deactivate.d"
cp "${RECIPE_DIR}/etc/conda/activate.d/brew-activate.sh" "${PREFIX}/etc/conda/activate.d/brew-activate.sh"
cp "${RECIPE_DIR}/etc/conda/deactivate.d/brew-deactivate.sh" "${PREFIX}/etc/conda/deactivate.d/brew-deactivate.sh"

# --- Verify portable Ruby metadata exists (binary not bundled — conda provides Ruby 4.0.x) ---
if [ ! -f "${HOMEBREW_INSTALL_DIR}/Library/Homebrew/vendor/portable-ruby-version" ]; then
  echo "Error: Portable Ruby metadata not found" >&2
  exit 1
fi

# --- Symlink brew CLI for PATH access ---
# Creates $PREFIX/bin/brew -> ../homebrew/bin/brew (relative, so it survives
# being installed into a different prefix than it was built in).
# Only symlinks the brew CLI itself to avoid shadowing conda packages with conflicting versions
mkdir -p "${PREFIX}/bin"
for name in brew brew-config _brew; do
    if [ -f "${HOMEBREW_INSTALL_DIR}/bin/${name}" ]; then
        ln -sf "../homebrew/bin/${name}" "${PREFIX}/bin/${name}"
    fi
done
