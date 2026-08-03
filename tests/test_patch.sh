#!/bin/bash
# tests/test_patch.sh — Validate the patch file applies cleanly against brew source.
# Clones brew into a temp dir, runs patch --dryrun, checks target files modified.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCH_FILE="$PROJECT_DIR/recipe/conda-brew-path-rewrite.patch"
VERSION="5.1.11"

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
    if echo "$haystack" | grep -qF "$needle"; then
        echo "   PASS $desc"
        PASS=$((PASS + 1))
    else
        echo "   FAIL $desc (contains: '$needle')"
        FAIL=$((FAIL + 1))
    fi
}

TMPDIR_PATCH=$(mktemp -d "${TMPDIR:-/tmp}/condabrew-patch-test-XXXXXX")
trap 'rm -rf "$TMPDIR_PATCH"' EXIT

echo ""
echo "=== Patch validation ==="

# Check patch file exists and is non-empty
if [ ! -s "$PATCH_FILE" ]; then
    echo "   FAIL patch file missing or empty"
    exit 1
fi
echo "   PASS patch file exists and non-empty"
PASS=$((PASS + 1))

# Read patch file to validate structure
patch_content="$(cat "$PATCH_FILE")"

check_contains "patch has unified diff header (diff --git)" "$patch_content" "diff --git"
check_contains "targets bottle_specification.rb" "$patch_content" "bottle_specification.rb"
check_contains "targets formula_installer.rb" "$patch_content" "formula_installer.rb"
check_contains "targets keg_relocate.rb" "$patch_content" "keg_relocate.rb"

# Check for key changes the patch should introduce:
# 1. relaxes compatible_locations? (cellar.is_a?(String) || cellar.size >= prefix.size)
# 2. forces skip_linkage = false
# 3. adds /opt/homebrew as a replacement pair
check_contains "relaxes compatible_locations for any cellar" "$patch_content" "size >="
check_contains "sets skip_linkage to false" "$patch_content" "skip_linkage = false"

echo ""

# Clone brew source and dry-run patch
echo "Cloning brew $VERSION source for dry-run..."
if git clone --depth 1 --branch "$VERSION" https://github.com/Homebrew/brew.git \
        "$TMPDIR_PATCH/brew-source" > /dev/null 2>&1; then
    echo "   Clone successful"

    # Apply patch with --dryrun inside the brew clone (paths are relative)
    DRYRUN_OK=false
    if (cd "$TMPDIR_PATCH/brew-source" && patch --dry-run -p1 --forward < "$PATCH_FILE" > "$TMPDIR_PATCH/patch.out" 2>&1); then
        DRYRUN_OK=true
    fi

    if [ "$DRYRUN_OK" = true ]; then
        echo "   PASS patch applies cleanly (--dryrun)"
        PASS=$((PASS + 1))
    else
        echo "   FAIL patch does NOT apply cleanly (--dryrun)"
        cat "$TMPDIR_PATCH/patch.out"
        FAIL=$((FAIL + 1))
    fi

    # Apply patch for real and diff against originals to confirm changes are meaningful
    if [ -d "$TMPDIR_PATCH/brew-source/Library/Homebrew" ]; then
        # Pre-patch snapshot of key files
        for ruby_file in bottle_specification.rb formula_installer.rb keg_relocate.rb; do
            target="$TMPDIR_PATCH/brew-source/Library/Homebrew/$ruby_file"
            if [ -f "$target" ]; then
                cp "$target" "${target}.orig"
            fi
        done

        # Actually apply patch (not dry-run) to verify changes are meaningful
        (cd "$TMPDIR_PATCH/brew-source" && patch -p1 --forward < "$PATCH_FILE" > "$TMPDIR_PATCH/apply.out" 2>&1) || true

        # Diff against originals to confirm real changes occurred
        for ruby_file in bottle_specification.rb formula_installer.rb keg_relocate.rb; do
            target="$TMPDIR_PATCH/brew-source/Library/Homebrew/$ruby_file"
            if [ -f "${target}.orig" ] && [ -f "$target" ]; then
                if ! diff -q "${target}.orig" "$target" > /dev/null 2>&1; then
                    echo "   PASS $ruby_file was modified by patch"
                    PASS=$((PASS + 1))
                else
                    echo "   FAIL $ruby_file unchanged after patch"
                    FAIL=$((FAIL + 1))
                fi
            fi
        done

        # Cleanup orig files
        rm -f "$TMPDIR_PATCH/brew-source/Library/Homebrew/"*.orig
    fi
else
    echo "   WARN brew clone failed (network), skipping dry-run"
    echo "   SKIP patch dry-run (could not clone brew source)"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "--- Patch: $PASS passed, $FAIL failed ---"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
