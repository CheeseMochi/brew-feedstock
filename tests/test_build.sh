#!/bin/bash
# tests/test_build.sh — Validate the conda-build output artifact.
# Runs: conda-build recipe/ , extracts tarball, checks paths.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RECIPE_DIR="$PROJECT_DIR/recipe"

# CEP-16 sharded repodata is still buggy as of 2026 -- shard fetches can 404
# and conda-build's internal solver calls don't reliably pick up a
# `conda config --set plugins.use_sharded_repodata false` change the way a
# plain `conda install` does.
export CONDA_PLUGINS_USE_SHARDED_REPODATA=0

PASS=0
FAIL=0

check() {
    local desc="$1" result="$2" expected="$3"
    if [ "$result" = "$expected" ]; then
        echo "   PASS $desc"
        PASS=$((PASS + 1))
    else
        echo "   FAIL $desc (expected: '$expected', got: '$result')"
        FAIL=$((FAIL + 1))
    fi
}

check_exists() {
    local desc="$1" path="$2"
    if [ -e "$path" ]; then
        echo "   PASS $desc ($path)"
        PASS=$((PASS + 1))
    else
        echo "   FAIL $desc (not found: $path)"
        FAIL=$((FAIL + 1))
    fi
}

# Confirm conda-brew-path-rewrite.patch actually landed in the *built
# artifact* -- conda-build applies patches inside its own isolated build
# sandbox, which is not guaranteed to have the same `patch` on PATH as this
# test's shell, so a passing patch dry-run (test_patch.sh) does not prove the
# real build picked it up. This caught a real bug where the sandbox fell back
# to macOS's ancient BSD patch, which silently skipped every hunk.
check_file_contains() {
    local desc="$1" file="$2" needle="$3"
    if [ -f "$file" ] && grep -qF -- "$needle" "$file"; then
        echo "   PASS $desc"
        PASS=$((PASS + 1))
    else
        echo "   FAIL $desc (missing '$needle' in $file -- patch did not apply in the built artifact)"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo "=== Build validation ==="

# Create temp dir for build artifacts and extraction
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/condabrew-build-test-XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "Running: conda-build recipe/ "

conda-build -c conda-forge "$RECIPE_DIR" \
    > "$BUILD_DIR/build.log" 2>&1 || {
    echo "   FAIL conda-build failed:"
    cat "$BUILD_DIR/build.log"
    exit 1
}

# Find the built package artifact
package_path=""

# Try standard conda-bld output locations first
CONDABREW_ENV_PREFIX="${CONDA_PREFIX:-}"
# Multiple build numbers can accumulate in conda-bld/ across rebuilds (e.g.
# brew-5.1.11-0.conda and brew-5.1.11-1.conda side by side) -- an unquoted
# glob here would expand to multiple words and silently pick whichever sorts
# first alphabetically (the stale, lowest build number), not the one just
# built. `ls -t | head -1` picks the most recently modified instead.
package_path=$(ls -t "$CONDABREW_ENV_PREFIX"/conda-bld/osx-arm64/brew-*.conda 2>/dev/null | head -1)
if [ -z "$package_path" ]; then
    package_path=$(ls -t "$CONDABREW_ENV_PREFIX"/conda-bld/osx-arm64/brew-*.tar.bz2 2>/dev/null | head -1)
fi

# Fallback: search recursively for any brew artifact. A permission error on
# some unrelated build/test sandbox dir elsewhere under conda-bld must not
# kill this script outright (set -e + pipefail would otherwise propagate it).
if [ -z "$package_path" ] && [ -n "$CONDABREW_ENV_PREFIX" ]; then
    package_path=$( { find "$CONDABREW_ENV_PREFIX" -name "brew-*.conda" -o -name "brew-*.tar.bz2"; } 2>/dev/null | head -1 || true)
fi

# Last fallback: check BUILD_DIR for any output
if [ -z "$package_path" ]; then
    package_path=$(find "$BUILD_DIR" \( -name "*.conda" -o -name "*.tar.bz2" \) 2>/dev/null | head -1)
fi

if [ -z "$package_path" ] || [ ! -f "$package_path" ]; then
    echo "   FAIL no build artifact found"
    cat "$BUILD_DIR/build.log"
    exit 1
fi

echo "   Package output: $package_path"
echo "   PASS artifact exists at: $package_path"

# Extract and validate contents
EXTRACT_DIR="$BUILD_DIR/pkg-extract"
mkdir -p "$EXTRACT_DIR"

case "$package_path" in
    *.conda)
        # .conda is a zip container holding pkg-*.tar.zst (the actual files)
        # and info-*.tar.zst (metadata) -- a plain `tar xf` opens the outer
        # zip "successfully" without erroring, but leaves the nested zstd
        # tarball (where homebrew/ actually lives) unextracted. Unzip, then
        # extract the nested pkg tarball.
        if unzip -q "$package_path" -d "$EXTRACT_DIR" 2>/dev/null; then
            pkg_tar_zst=$(find "$EXTRACT_DIR" -maxdepth 1 -name "pkg-*.tar.zst" | head -1)
            if [ -n "$pkg_tar_zst" ] && tar xf "$pkg_tar_zst" -C "$EXTRACT_DIR" 2>/dev/null; then
                echo "   PASS package extracted (.conda: unzip + zstd tar)"
            else
                echo "   FAIL could not extract nested pkg-*.tar.zst from .conda package"
                exit 1
            fi
        else
            echo "   FAIL could not unzip .conda package"
            exit 1
        fi
        ;;
    *.tar.bz2)
        if tar xf "$package_path" -C "$EXTRACT_DIR" 2>/dev/null; then
            echo "   PASS package extracted with tar"
        else
            echo "   FAIL could not extract .tar.bz2 package"
            exit 1
        fi
        ;;
    *)
        echo "   FAIL unrecognized package format: $package_path"
        exit 1
        ;;
esac

# Check key paths in extracted package
homebrew_dir="$EXTRACT_DIR/homebrew"

check_exists "$homebrew_dir/bin/brew exists" "$homebrew_dir/bin/brew"
check_exists "$homebrew_dir/etc/homebrew/brew.env exists" "$homebrew_dir/etc/homebrew/brew.env"
check "Library/Homebrew/ contains ruby files" \
    "$(ls "$homebrew_dir/Library/Homebrew/"*.rb 1>/dev/null 2>&1 && echo y || echo n)" "y"

# conda's activate/deactivate hooks live at the package root (etc/conda/...),
# not under homebrew/ -- these were silently never being packaged at all
# (build.sh never copied them from the recipe), so HOMEBREW_NO_AUTO_UPDATE
# was never actually set on `conda activate`, and `brew install` would run
# an implicit `brew update` that re-clones Homebrew's repo and undoes every
# patch, every time.
check_exists "etc/conda/activate.d/brew-activate.sh exists" \
    "$EXTRACT_DIR/etc/conda/activate.d/brew-activate.sh"
check_exists "etc/conda/deactivate.d/brew-deactivate.sh exists" \
    "$EXTRACT_DIR/etc/conda/deactivate.d/brew-deactivate.sh"
check_file_contains "brew.env sets HOMEBREW_NO_AUTO_UPDATE" \
    "$homebrew_dir/etc/homebrew/brew.env" "HOMEBREW_NO_AUTO_UPDATE=1"

echo ""
echo "--- Patch landed in built artifact ---"
check_file_contains "bottle_specification.rb: cellar == :any relaxation" \
    "$homebrew_dir/Library/Homebrew/bottle_specification.rb" "cellar == :any"
check_file_contains "formula_installer.rb: skip_linkage forced false" \
    "$homebrew_dir/Library/Homebrew/formula_installer.rb" "Always run relocation"
check_file_contains "keg_relocate.rb: /opt/homebrew replacement pair" \
    "$homebrew_dir/Library/Homebrew/keg_relocate.rb" "default_macos_arm"
check_file_contains "bin/brew: HOMEBREW_PREFIX aligned with resolved repository" \
    "$homebrew_dir/bin/brew" 'HOMEBREW_PREFIX="${HOMEBREW_REPOSITORY}"'

# Verify no portable Ruby binaries are bundled (Ruby 4.0.x comes from conda)
vendor_count=$(find "$homebrew_dir/Library/Homebrew/vendor" -maxdepth 1 -type d \
    -name "portable-ruby-*" 2>/dev/null | wc -l | tr -d ' ')
if [ "$vendor_count" -eq 0 ]; then
    echo "   PASS no portable Ruby binaries bundled (Ruby 4.0.x from conda, count=$vendor_count)"
else
    echo "   WARN portable Ruby binaries found (count=$vendor_count, expected 0)"
fi

# Validate meta.yaml structure with Python
echo ""
echo "--- YAML validation ---"
if python3 -c "
import yaml, sys
with open('$RECIPE_DIR/meta.yaml') as f:
    meta = yaml.safe_load(f)
assert meta['package']['name'] == 'brew', 'Wrong package name'
assert 'version' in meta['package'], 'Missing version'
assert 'source' in meta, 'Missing source'
assert 'build' in meta, 'Missing build'
assert 'test' in meta, 'Missing test'
print('meta.yaml: valid structure')
" > "$BUILD_DIR/yaml.log" 2>&1; then
    echo "   PASS meta.yaml has valid conda recipe structure"
else
    echo "   FAIL meta.yaml validation:"
    cat "$BUILD_DIR/yaml.log"
fi

echo ""
echo "--- Build: $PASS passed, $FAIL failed ---"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
