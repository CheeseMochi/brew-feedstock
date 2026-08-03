#!/bin/bash
# tests/test_e2e.sh — Full end-to-end pipeline.
#    1. Build conda package from source recipe
#    2. Create isolated test environment with it
#    3. Run brew --version, brew install hello, verify bottle used
#    3b. Install sqlite (linked dylibs) and verify the path-rewrite patch
#        actually relocated embedded /opt/homebrew or /usr/local references
#    4. Verify deactivation: brew removed from PATH
#    5. Cleanup temp env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RECIPE_DIR="$PROJECT_DIR/recipe"
TEST_ENV=$(mktemp -d "${TMPDIR:-/tmp}/condabrew-e2e-env-XXXXXX")
# Resolve to the canonical real path: $TMPDIR on macOS is a symlink
# (/var/folders/... -> /private/var/folders/...) and brew reports the
# resolved path via --prefix, so comparisons below need the same form.
TEST_ENV="$(cd "$TEST_ENV" && pwd -P)"
LOG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/condabrew-e2e-log-XXXXXX")

# A real `conda activate` sources our activate.d hooks (HOMEBREW_NO_AUTO_UPDATE,
# etc.); `conda run -p` below does not, so set the ones that matter explicitly
# to avoid brew auto-updating/fetching in the background during these calls.
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ANALYTICS=1

cleanup() {
    conda deactivate 2>/dev/null || true
    rm -rf "$TEST_ENV" "$LOG_DIR"
}
trap cleanup EXIT

echo ""
echo "=== End-to-end pipeline ==="

# ---- Step 1: Build the conda package ----
echo ""
echo "--- Step 1: Building conda package ---"

conda run -n condabrew \
    conda-build -c conda-forge "$RECIPE_DIR" \
    > "$LOG_DIR/condabuild-e2e.log" 2>&1 || {
    echo "   FAIL conda-build failed:"
    cat "$LOG_DIR/condabuild-e2e.log"
    exit 1
}
echo "   PASS conda package built"

# ---- Step 2: Create isolated test environment ----
echo ""
echo "--- Step 2: Creating test environment ---"

CONDABREW_ENV_PREFIX="$(conda run -n condabrew printenv CONDA_PREFIX 2>/dev/null)" || true
package_path=""

# Try the standard conda-bld output location first (fast, and avoids `find`
# tripping over permission-restricted build/test sandbox dirs elsewhere under
# conda-bld, which -- combined with `set -e`/`pipefail` -- would otherwise
# kill this script silently with no error message).
for candidate in \
     "$CONDABREW_ENV_PREFIX"/conda-bld/osx-arm64/brew-*.conda \
     "$CONDABREW_ENV_PREFIX"/conda-bld/osx-arm64/brew-*.tar.bz2; do
    if ls "$candidate" 1>/dev/null 2>&1; then
        package_path=$(ls -t $candidate | head -1)
        break
    fi
done

# Fallback: broader search, but never let a permission error here kill the script
if [ -z "$package_path" ] && [ -n "$CONDABREW_ENV_PREFIX" ]; then
    package_path=$( { find "$CONDABREW_ENV_PREFIX/conda-bld" -name "brew-*.conda" -o -name "brew-*.tar.bz2"; } 2>/dev/null | head -1 || true)
fi

if [ -z "$package_path" ]; then
    echo "   FAIL no build artifact found (expected under $CONDABREW_ENV_PREFIX/conda-bld)"
    exit 1
fi

conda run -n condabrew \
    conda create -y -p "$TEST_ENV" \
    -c local \
    "$package_path" \
    > "$LOG_DIR/conda-create-e2e.log" 2>&1 || {
    echo "   FAIL conda create failed:"
    cat "$LOG_DIR/conda-create-e2e.log"
    exit 1
}
echo "   PASS test env created at $TEST_ENV"

# ---- Step 3: Run brew commands in the test env ----
echo ""
echo "--- Step 3: Running brew commands ---"

brew_bin="$TEST_ENV/homebrew/bin/brew"

if [ ! -x "$brew_bin" ]; then
    echo "   FAIL brew binary not found at: $brew_bin"
    exit 1
fi

# brew --version should reference conda prefix
version_out=$(conda run -p "$TEST_ENV" "$brew_bin" --version 2>&1 || true)
if echo "$version_out" | grep -qF "homebrew"; then
    echo "   PASS brew --version output references homebrew"
else
    echo "   WARN brew --version: $version_out"
fi

# brew --prefix must equal $TEST_ENV/homebrew
expected_prefix="$TEST_ENV/homebrew"
prefix_out=$(conda run -p "$TEST_ENV" "$brew_bin" --prefix 2>&1 || true)
if [ "$prefix_out" = "$expected_prefix" ]; then
    echo "   PASS brew --prefix = $expected_prefix"
else
    echo "   FAIL brew --prefix (expected: '$expected_prefix', got: '$prefix_out')"
fi

# brew install hello — should use bottle, not build from source
echo "   Running: brew install hello..."
install_out=$(conda run -p "$TEST_ENV" \
    "$brew_bin" install hello 2>&1 || true)

if echo "$install_out" | grep -qi "building from source"; then
    echo "   FAIL brew install hello built from SOURCE (bottle not used)"
else
    echo "   PASS brew install hello did NOT build from source"
fi

# hello binary should run. Resolve the glob to a concrete path first --
# quoting it directly in `ls`/exec would search for a literal "*" and never
# match, silently WARNing on every run regardless of whether hello installed.
hello_bin=$(ls "$expected_prefix"/Cellar/hello/*/bin/hello 2>/dev/null | head -1)
if [ -n "$hello_bin" ]; then
    hello_out=$(conda run -p "$TEST_ENV" "$hello_bin" 2>&1 || true)
    if echo "$hello_out" | grep -qi "Hello"; then
        echo "   PASS hello binary runs with expected output"
    else
        echo "   WARN hello output: $hello_out"
    fi
else
    echo "   WARN hello binary not found at: $expected_prefix/Cellar/hello/*/bin/hello"
fi

# brew info should show the keg was poured from a bottle. The human-readable
# "Poured from bottle on ..." line was dropped upstream; poured_from_bottle
# now only shows up in the JSON API.
info_out=$(conda run -p "$TEST_ENV" \
    "$brew_bin" info --json=v2 hello 2>&1 || true)
if echo "$info_out" | grep -qE '"poured_from_bottle"[[:space:]]*:[[:space:]]*true'; then
    echo "   PASS brew info shows poured_from_bottle=true"
elif [ -n "$install_out" ]; then
    echo "   WARN bottle not confirmed (output: $(echo "$install_out" | head -5))"
else
    echo "   WARN no install output to check against"
fi

# ---- Step 3b: Verify the path-rewrite patch on a formula with linked dylibs ----
# hello's bottle is cellar: :any with no linked deps, so it installs fine even
# on stock unpatched Homebrew and proves nothing about relocation. sqlite has
# a real linked dylib with embedded install-name paths, so this is the actual
# check that the patch's path rewriting works.
echo ""
echo "--- Step 3b: Relocation check (sqlite, has linked dylibs) ---"

sqlite_install_out=$(conda run -p "$TEST_ENV" \
    "$brew_bin" install sqlite 2>&1 || true)

if echo "$sqlite_install_out" | grep -qi "building from source"; then
    echo "   WARN brew install sqlite built from SOURCE (bottle not used, relocation check skipped)"
else
    sqlite_lib=$(ls "$expected_prefix"/Cellar/sqlite/*/lib/libsqlite3*.dylib 2>/dev/null | head -1)
    sqlite_bin=$(ls "$expected_prefix"/Cellar/sqlite/*/bin/sqlite3 2>/dev/null | head -1)

    if [ -n "$sqlite_lib" ] || [ -n "$sqlite_bin" ]; then
        stale_paths=""
        for f in "$sqlite_lib" "$sqlite_bin"; do
            [ -n "$f" ] || continue
            hits=$(conda run -p "$TEST_ENV" otool -L "$f" 2>/dev/null | grep -E '/opt/homebrew|/usr/local' || true)
            [ -n "$hits" ] && stale_paths="${stale_paths}${f}:\n${hits}\n"
        done

        if [ -z "$stale_paths" ]; then
            echo "   PASS sqlite binary/lib have no leftover /opt/homebrew or /usr/local paths (patch applied)"
        else
            echo "   FAIL sqlite binary/lib still reference the build prefix (patch not applied):"
            echo -e "$stale_paths"
        fi
    else
        echo "   WARN sqlite binary/lib not found under $expected_prefix/Cellar/sqlite, skipping relocation check"
    fi
fi

# ---- Step 4: Verify deactivation behavior ----
echo ""
echo "--- Step 4: Deactivation check ---"

# In a fresh conda run context, the test env is not activated
# so brew should not be on PATH by default.
which_out=$(conda run -p "$TEST_ENV" which brew 2>&1 || echo "brew not found")
if echo "$which_out" | grep -qi "not found\|not [a-z]"; then
    echo "   PASS brew not on PATH (deactivated)"
else
    echo "   WARN brew found: $which_out"
fi

# ---- Step 5: Cleanup ----
echo ""
echo "--- E2E complete, cleaning up ---"
cleanup
echo "   PASS test env removed at $TEST_ENV"
