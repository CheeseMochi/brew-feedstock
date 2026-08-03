#!/bin/bash
# tests/test_scripts.sh — Validate activate/deactivate/post-link scripts.
# Runs without conda: each script is sourced with a mock $CONDA_PREFIX.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RECIPE_DIR="$PROJECT_DIR/recipe"
FAKE_PREFIX=$(mktemp -d "${TMPDIR:-/tmp}/fake-condabrew-env-XXXXXX")

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

check_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        echo "   PASS $desc"
        PASS=$((PASS + 1))
    else
        echo "   FAIL $desc (contains: '$needle') — haystack='$haystack'"
        FAIL=$((FAIL + 1))
    fi
}

check_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if ! echo "$haystack" | grep -qF -- "$needle"; then
        echo "   PASS $desc"
        PASS=$((PASS + 1))
    else
        echo "   FAIL $desc (should NOT contain: '$needle')"
        FAIL=$((FAIL + 1))
    fi
}

# ============================================================
# ACTIVATE.SH TESTS
# ============================================================

echo ""
echo "=== brew-activate.sh ==="

# Extract script content into a function we can source with mock prefix
_eval_activate() {
    export CONDA_PREFIX="$FAKE_PREFIX"
    local PATH_BEFORE="$PATH"
    # Simulate conda's PATH prepend: conda always does $PREFIX/bin:$PATH first
    export PATH="${CONDA_PREFIX}/bin:${PATH_BEFORE}"

    # Source brew-activate.sh logic inline (not as an include, to control PATH)
    eval "$(cat "$RECIPE_DIR/etc/conda/activate.d/brew-activate.sh")"

    _ACT_PATH="$PATH"
    _ACT_HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-<unset>}"
    _ACT_HOMEBREW_CELLAR="${HOMEBREW_CELLAR:-<unset>}"
    _ACT_HOMEBREW_REPOSITORY="${HOMEBREW_REPOSITORY:-<unset>}"
    _ACT_HOMEBREW_LIBRARY="${HOMEBREW_LIBRARY:-<unset>}"
    _ACT_HOMEBREW_USER_CONFIG_HOME="${HOMEBREW_USER_CONFIG_HOME:-<unset>}"
    _ACT_HOMEBREW_NO_AUTO_UPDATE="${HOMEBREW_NO_AUTO_UPDATE:-<unset>}"
    _ACT_HOMEBREW_NO_ANALYTICS="${HOMEBREW_NO_ANALYTICS:-<unset>}"
}

_eval_activate

FAKE_PREFIX_HOME="$FAKE_PREFIX/homebrew"

check_contains  "PATH contains homebrew bin" "$_ACT_PATH" "$FAKE_PREFIX/homebrew/bin:"
check_contains  "PATH contains homebrew sbin" "$_ACT_PATH" "$FAKE_PREFIX/homebrew/sbin:"
check           "HOMEBREW_PREFIX set" "$_ACT_HOMEBREW_PREFIX" "$FAKE_PREFIX_HOME"
check           "HOMEBREW_CELLAR set" "$_ACT_HOMEBREW_CELLAR" "$FAKE_PREFIX_HOME/Cellar"
check           "HOMEBREW_REPOSITORY set" "$_ACT_HOMEBREW_REPOSITORY" "$FAKE_PREFIX_HOME"
check           "HOMEBREW_LIBRARY set" "$_ACT_HOMEBREW_LIBRARY" "$FAKE_PREFIX_HOME/Library"
check           "HOMEBREW_USER_CONFIG_HOME set" "$_ACT_HOMEBREW_USER_CONFIG_HOME" "$FAKE_PREFIX_HOME"
check           "HOMEBREW_NO_AUTO_UPDATE=1" "$_ACT_HOMEBREW_NO_AUTO_UPDATE" "1"
check           "HOMEBREW_NO_ANALYTICS=1" "$_ACT_HOMEBREW_NO_ANALYTICS" "1"

# Verify completions are sourced (check the script contains sourcing logic)
activate_script="$(cat "$RECIPE_DIR/etc/conda/activate.d/brew-activate.sh")"
check_contains  "zsh completion sourced" "$activate_script" 'ZSH_VERSION'
check_contains  "fish completion added" "$activate_script" 'FISH_VERSION'

# Regression test: conda-build's own package test harness activates a test
# env from *inside* an already-active build env, so $CONDA_PREFIX/bin is not
# necessarily the literal first PATH entry -- only somewhere in it. A prior
# version of this script only checked the literal prefix, silently leaving
# homebrew/bin off PATH (and `brew doctor`/`hello` failing) whenever anything
# preceded $CONDA_PREFIX/bin.
_eval_activate_nested_path() {
    export CONDA_PREFIX="$FAKE_PREFIX"
    # Simulate PATH where $CONDA_PREFIX/bin is present but NOT the first entry
    export PATH="/some/other/tool/bin:${CONDA_PREFIX}/bin:/usr/bin:/bin"

    eval "$(cat "$RECIPE_DIR/etc/conda/activate.d/brew-activate.sh")"

    _ACT_NESTED_PATH="$PATH"
}

_eval_activate_nested_path

check_contains "PATH contains homebrew bin when \$CONDA_PREFIX/bin isn't first" \
    "$_ACT_NESTED_PATH" "$FAKE_PREFIX/homebrew/bin:"
check_contains "PATH still has the entry before \$CONDA_PREFIX/bin" \
    "$_ACT_NESTED_PATH" "/some/other/tool/bin:"
check_contains  "bash completion sourced" "$activate_script" 'BASH_VERSION'

# ============================================================
# DEACTIVATE.SH TESTS
# ============================================================

echo ""
echo "=== brew-deactivate.sh ==="

_eval_deactivate() {
    export CONDA_PREFIX="$FAKE_PREFIX"
    # Set up a PATH that includes brew bin+sbin (as activate would have done, after conda's bin)
    export PATH="${FAKE_PREFIX}/bin:${FAKE_PREFIX}/homebrew/bin:${FAKE_PREFIX}/homebrew/sbin:/usr/local/bin:/usr/bin:/bin"

    # Source brew-deactivate.sh logic inline
    eval "$(cat "$RECIPE_DIR/etc/conda/deactivate.d/brew-deactivate.sh")"

    _DEACT_PATH="$PATH"
    _DEACT_HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-<set>}"
}

_eval_deactivate

check_contains  "brew bin removed from PATH" "$_DEACT_PATH" "/usr/local/bin:/usr/bin"
check_not_contains "brew bin NOT in remaining PATH" "$_DEACT_PATH" "$FAKE_PREFIX_HOME"
# HOMEBREW vars should be unset after deactivation (eval of source doesn't persist them if we test differently)
# Since eval runs in same shell, _DEACT_HOMEBREW_PREFIX would still be set from activate.
# We need to verify the script actually has unset commands.
deactivate_script="$(cat "$RECIPE_DIR/etc/conda/deactivate.d/brew-deactivate.sh")"
check_contains  "unset HOMEBREW_PREFIX" "$deactivate_script" 'unset HOMEBREW_PREFIX'
check_contains  "unset HOMEBREW_CELLAR" "$deactivate_script" 'unset HOMEBREW_CELLAR'
check_contains  "unset HOMEBREW_REPOSITORY" "$deactivate_script" 'unset HOMEBREW_REPOSITORY'
check_contains  "unset HOMEBREW_LIBRARY" "$deactivate_script" 'unset HOMEBREW_LIBRARY'
check_contains  "unset HOMEBREW_USER_CONFIG_HOME" "$deactivate_script" 'unset HOMEBREW_USER_CONFIG_HOME'
check_contains  "unset HOMEBREW_NO_AUTO_UPDATE" "$deactivate_script" 'unset HOMEBREW_NO_AUTO_UPDATE'
check_contains  "unset HOMEBREW_NO_ANALYTICS" "$deactivate_script" 'unset HOMEBREW_NO_ANALYTICS'

# ============================================================
# POST_LINK.SH TESTS
# ============================================================

echo ""
echo "=== post-link.sh ==="

# Test directory creation logic by extracting mkdir lines and running them.
# post-link.sh runs as a conda link script, which gets $PREFIX (not
# $CONDA_PREFIX -- that's an activation-only variable), so that's what gets
# injected here too, matching the real invocation contract.
_eval_postlink() {
    export PREFIX="$FAKE_PREFIX"

    # Run the mkdir commands from post-link.sh (not the brew doctor line, since no real brew)
    eval "$(grep 'mkdir -p' "$RECIPE_DIR/post-link.sh")"

    _POSTLINK_DIRS=(
        "$FAKE_PREFIX/homebrew/Cellar"
        "$FAKE_PREFIX/homebrew/opt"
        "$FAKE_PREFIX/homebrew/var/homebrew/Cache"
        "$FAKE_PREFIX/homebrew/var/homebrew/linked"
    )
}

_eval_postlink

for dir in "${_POSTLINK_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        echo "   PASS directory exists: $dir"
        PASS=$((PASS + 1))
    else
        echo "   FAIL directory not created: $dir"
        FAIL=$((FAIL + 1))
    fi
done

# Verify post-link.sh runs brew doctor without the --warn-only flag
# (removed upstream; not a valid brew doctor flag at the pinned version)
post_link_content="$(cat "$RECIPE_DIR/post-link.sh")"
check_contains     "runs brew doctor" "$post_link_content" "brew doctor"
check_not_contains "does not pass --warn-only" "$post_link_content" "--warn-only"

# Cleanup
rm -rf "$FAKE_PREFIX"

echo ""
echo "--- Scripts: $PASS passed, $FAIL failed ---"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
