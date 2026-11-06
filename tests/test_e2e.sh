#!/bin/bash
# tests/test_e2e.sh — Full end-to-end pipeline.
#    1. Build conda package from source recipe
#    2. Create isolated test environment with it
#    3. Run brew --version, brew install hello, verify bottle used
#    3b. Install sqlite (linked dylibs) and verify the path-rewrite patch
#        actually relocated embedded /opt/homebrew or /usr/local references
#    3c. Install openssl@3 (hardcoded absolute data paths) and verify the
#        build-prefix size mismatch warns-and-skips instead of aborting
#    4. Verify deactivation: brew removed from PATH
#    5. Cleanup temp env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RECIPE_DIR="$PROJECT_DIR/recipe"

# CEP-16 sharded repodata is still buggy as of 2026 -- shard fetches can 404
# and conda-build's/conda create's internal solver calls don't reliably pick
# up a `conda config --set plugins.use_sharded_repodata false` change the way
# a plain `conda install` does.
export CONDA_PLUGINS_USE_SHARDED_REPODATA=0

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

CONDABREW_ENV_PREFIX="${CONDA_PREFIX:-}"
package_path=""

# Try the standard conda-bld output location first (fast, and avoids `find`
# tripping over permission-restricted build/test sandbox dirs elsewhere under
# conda-bld, which -- combined with `set -e`/`pipefail` -- would otherwise
# kill this script silently with no error message).
# Sort the whole glob by mtime: old versions accumulate in conda-bld/, and
# anything that takes the first glob match gets the alphabetically oldest
# build rather than the one Step 1 just produced.
package_path=$(ls -t "$CONDABREW_ENV_PREFIX"/conda-bld/osx-arm64/brew-*.conda \
    "$CONDABREW_ENV_PREFIX"/conda-bld/osx-arm64/brew-*.tar.bz2 2>/dev/null | head -1 || true)

# Fallback: broader search, but never let a permission error here kill the script
if [ -z "$package_path" ] && [ -n "$CONDABREW_ENV_PREFIX" ]; then
    package_path=$( { find "$CONDABREW_ENV_PREFIX/conda-bld" -name "brew-*.conda" -o -name "brew-*.tar.bz2"; } 2>/dev/null | head -1 || true)
fi

if [ -z "$package_path" ]; then
    echo "   FAIL no build artifact found (expected under $CONDABREW_ENV_PREFIX/conda-bld)"
    exit 1
fi

conda create -y -p "$TEST_ENV" \
    -c local \
    "$package_path" \
    > "$LOG_DIR/conda-create-e2e.log" 2>&1 || {
    echo "   FAIL conda create failed:"
    cat "$LOG_DIR/conda-create-e2e.log"
    exit 1
}
echo "   PASS test env created at $TEST_ENV from $(basename "$package_path")"

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
# Capture the exit code: without it a failed install has no "building from
# source" line either, and would report PASS below.
install_out=$(conda run -p "$TEST_ENV" \
    "$brew_bin" install hello 2>&1) && install_rc=0 || install_rc=$?

if [ "$install_rc" -ne 0 ]; then
    echo "   FAIL brew install hello exited $install_rc:"
    echo "$install_out" | tail -20 | sed 's/^/        /'
elif echo "$install_out" | grep -qi "building from source"; then
    echo "   FAIL brew install hello built from SOURCE (bottle not used)"
else
    echo "   PASS brew install hello did NOT build from source"
fi

# hello binary should run. Resolve the glob to a concrete path first --
# quoting it directly in `ls`/exec would search for a literal "*" and never
# match, silently WARNing on every run regardless of whether hello installed.
# `|| true`: see the note on openssl_dir in Step 3c.
hello_bin=$(ls "$expected_prefix"/Cellar/hello/*/bin/hello 2>/dev/null | head -1 || true)
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
    "$brew_bin" install sqlite 2>&1) && sqlite_rc=0 || sqlite_rc=$?

if [ "$sqlite_rc" -ne 0 ]; then
    echo "   FAIL brew install sqlite exited $sqlite_rc:"
    echo "$sqlite_install_out" | tail -20 | sed 's/^/        /'
elif echo "$sqlite_install_out" | grep -qi "building from source"; then
    echo "   WARN brew install sqlite built from SOURCE (bottle not used, relocation check skipped)"
else
    sqlite_lib=$(ls "$expected_prefix"/Cellar/sqlite/*/lib/libsqlite3*.dylib 2>/dev/null | head -1 || true)
    sqlite_bin=$(ls "$expected_prefix"/Cellar/sqlite/*/bin/sqlite3 2>/dev/null | head -1 || true)

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

# ---- Step 3c: Build-prefix skip check (openssl@3, hardcoded absolute data paths) ----
# Different failure class from sqlite's. sqlite's dylib references are
# placeholder tokens (@@HOMEBREW_PREFIX@@) that replace_placeholders_with_locations
# rewrites cleanly at any length. openssl@3's bottle additionally bakes *literal*
# absolute paths into binary data -- OPENSSLDIR and MODULESDIR, e.g.
# /opt/homebrew/etc/openssl@3/cert.pem inside libcrypto.3.dylib and libcrypto.a.
# Those go through relocate_build_prefix, which rewrites in place with null
# padding and so can only shrink or hold length. A conda prefix is always far
# longer than /opt/homebrew (13 chars), so the rewrite never fits: stock Homebrew
# raises "Patching failed! Original and patched binary sizes do not match" and
# aborts the entire install. The patch downgrades that to a warning and skips the
# file. A published build cut before that hunk existed shipped and broke exactly
# here, on `brew install openssl@3`, which nothing in this suite caught --
# hello and sqlite have no literal /opt/homebrew strings in their binaries.
echo ""
echo "--- Step 3c: Build-prefix skip check (openssl@3, hardcoded data paths) ---"

# Capture the exit code rather than swallowing it with `|| true`: a restored
# raise makes brew exit non-zero, and under `set -e` that would kill this
# script before any FAIL line printed (run.sh would report CRASHED instead).
openssl_install_out=$(conda run -p "$TEST_ENV" \
    "$brew_bin" install openssl@3 2>&1) && openssl_rc=0 || openssl_rc=$?

if echo "$openssl_install_out" | grep -qF "Patching failed"; then
    echo "   FAIL brew install openssl@3 aborted on the build-prefix size mismatch"
    echo "        (keg_relocate.rb warn-and-skip hunk missing from this build):"
    echo "$openssl_install_out" | grep -F -A3 "Patching failed" | sed 's/^/        /'
elif [ "$openssl_rc" -ne 0 ]; then
    echo "   FAIL brew install openssl@3 exited $openssl_rc:"
    echo "$openssl_install_out" | tail -20 | sed 's/^/        /'
else
    echo "   PASS brew install openssl@3 completed (size mismatch did not abort the install)"
fi

# `|| true` is load-bearing: under `set -euo pipefail` an unmatched glob makes
# `ls` fail, pipefail propagates that through `head`, and the assignment then
# kills the whole script -- so the "keg not found" FAIL below would never print
# and run.sh would report CRASHED with no explanation instead.
openssl_dir=$(ls -d "$expected_prefix"/Cellar/openssl@3/* 2>/dev/null | head -1 || true)

if [ "$openssl_rc" -ne 0 ]; then
    # Already reported above. A failed pour can leave a partial keg behind, so
    # the checks below would report misleading secondary failures.
    echo "   WARN openssl@3 install did not complete -- remaining openssl checks skipped"
elif [ -z "$openssl_dir" ]; then
    echo "   FAIL openssl@3 keg not found under $expected_prefix/Cellar/openssl@3"
elif echo "$openssl_install_out" | grep -qi "building from source"; then
    echo "   WARN openssl@3 built from SOURCE -- a source build has no foreign build"
    echo "        prefix to relocate, so the skip path was never exercised; remaining"
    echo "        openssl checks skipped"
else
    # The warning is corroborating, not decisive (the FAIL above is the real
    # guard). WARN rather than FAIL if it's absent: upstream could republish
    # openssl@3 as a relocatable `cellar: :any` bottle, which would legitimately
    # bypass relocate_build_prefix entirely -- that needs a human look, not a
    # red build.
    if echo "$openssl_install_out" | grep -qF "Skipping build-prefix patch"; then
        echo "   PASS relocate_build_prefix warned and skipped instead of raising"
    else
        echo "   WARN no 'Skipping build-prefix patch' warning seen -- the openssl@3"
        echo "        bottle may have become relocatable upstream; re-check whether"
        echo "        this step still guards anything"
    fi

    # Dynamic linkage must survive the bailout. This does NOT verify the skipped
    # data strings -- openssl's install names are @@HOMEBREW_PREFIX@@ placeholders
    # handled by a separate code path, so otool never sees /opt/homebrew here
    # either way. What it confirms is that skipping a file mid-relocation didn't
    # leave placeholder tokens unresolved or linkage pointing outside the env.
    stale_linkage=""
    for f in "$openssl_dir/lib/libcrypto.3.dylib" \
             "$openssl_dir/lib/libssl.3.dylib" \
             "$openssl_dir/bin/openssl"; do
        [ -e "$f" ] || continue
        hits=$(conda run -p "$TEST_ENV" otool -L "$f" 2>/dev/null \
            | grep -E '/opt/homebrew|/usr/local|@@HOMEBREW_' || true)
        [ -n "$hits" ] && stale_linkage="${stale_linkage}${f}:\n${hits}\n"
    done

    if [ -z "$stale_linkage" ]; then
        echo "   PASS openssl@3 linkage fully resolved (no /opt/homebrew, /usr/local or @@HOMEBREW_ placeholders)"
    else
        echo "   FAIL openssl@3 linkage still references the build prefix or unresolved placeholders:"
        echo -e "$stale_linkage" | sed 's/^/        /'
    fi

    # Pin the known limitation as an assertion rather than a comment. A skipped
    # file must be left byte-identical, so the literal build-prefix string is
    # still expected to be present. If it ever goes missing, either the bottle
    # became relocatable (re-examine this step) or relocation started truncating
    # instead of skipping -- a partial rewrite is worse than the skip.
    # LC_ALL=C grep -a, not `strings`: strings(1) shells out to xcrun and fails
    # when it can't write its cache.
    crypto_lib="$openssl_dir/lib/libcrypto.3.dylib"
    if [ -f "$crypto_lib" ]; then
        if LC_ALL=C grep -qaF "/opt/homebrew/etc/openssl@3" "$crypto_lib"; then
            echo "   PASS libcrypto.3.dylib left intact with its unrewritten OPENSSLDIR (expected: file was skipped whole)"
        else
            echo "   FAIL libcrypto.3.dylib no longer contains /opt/homebrew/etc/openssl@3 --"
            echo "        a skipped file must be byte-identical; check for a partial rewrite"
        fi
    else
        echo "   WARN libcrypto.3.dylib not found at $crypto_lib, skipping data-path check"
    fi

    # Known limitation, with a pinned value: OPENSSLDIR keeps pointing at
    # /opt/homebrew, which does not exist in a conda-scoped install, so brew's
    # openssl finds no cert.pem and TLS verification fails for anything linked
    # against it (workaround: SSL_CERT_FILE/SSL_CERT_DIR). WARN, because it is
    # the accepted trade-off for pouring instead of building from source -- but
    # any *other* value means the rewrite corrupted the path, which is a FAIL.
    openssl_bin="$openssl_dir/bin/openssl"
    if [ -x "$openssl_bin" ]; then
        openssldir_out=$(conda run -p "$TEST_ENV" "$openssl_bin" version -d 2>&1 || true)
        # Separate "didn't run" from "ran and reported an unexpected path" -- an
        # un-relocated keg fails here with a dyld "Symbol not found" instead of
        # any OPENSSLDIR line at all, and reporting that as a corrupt rewrite
        # would send the next reader down the wrong path.
        if ! echo "$openssldir_out" | grep -q "OPENSSLDIR:"; then
            echo "   FAIL openssl binary did not run -- linkage broken after relocation:"
            echo "$openssldir_out" | head -5 | sed 's/^/        /'
        else
            case "$openssldir_out" in
                *"/opt/homebrew/etc/openssl@3"*)
                    echo "   WARN OPENSSLDIR still /opt/homebrew/etc/openssl@3 (known limitation:"
                    echo "        skipped file keeps its build-prefix path; TLS needs SSL_CERT_FILE)" ;;
                *"$expected_prefix"*)
                    echo "   PASS OPENSSLDIR relocated into the conda prefix: $openssldir_out" ;;
                *)
                    echo "   FAIL OPENSSLDIR is neither the known-bad literal nor the conda prefix"
                    echo "        (corrupt rewrite?): $openssldir_out" ;;
            esac
        fi
    else
        echo "   WARN openssl binary not found at $openssl_bin, skipping OPENSSLDIR check"
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
