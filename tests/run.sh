#!/bin/bash
# tests/run.sh — Entry point for condabrew test suite.
# Usage: ./run.sh [quick|e2e|scripts|patch|build|all]
#   quick      Run scripts, patch, build (skip slow e2e)     — default
#   e2e        Run only end-to-end tests
#   scripts    Run only shell script validation
#   patch      Run only patch validation
#   build      Run only build validation
#   all        Run everything including e2e

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
CYAN="\033[0;36m"
NC="\033[0m"

pass_count=0
fail_count=0
skip_count=0

# Execute a single test group; aggregate pass/fail from its output.
run_group() {
    local group="$1"
    local file="$SCRIPT_DIR/test_${group}.sh"

    echo ""
    echo -e "${CYAN}=== Test: ${group} ===${NC}"

    if [ ! -f "$file" ]; then
        echo "   ${YELLOW}SKIP${NC} test_${group}.sh not found"
        skip_count=$((skip_count + 1))
        return 0
    fi

    # Capture output and exit code to compute per-group stats. A group's exit
    # code is checked independently of its PASS/FAIL line count: a script that
    # dies early (e.g. via `set -e`, a crash) without ever echoing an explicit
    # "FAIL" line must still count as a failure, or the summary below would
    # silently report success on a run that never actually finished.
    local output exit_code gpass gfail
    output=$(bash "$file" 2>&1)
    exit_code=$?
    echo "$output"

    gpass=$(echo "$output" | grep -c "   PASS" || true)
    gfail=$(echo "$output" | grep -c "   FAIL" || true)
    pass_count=$((pass_count + gpass))
    fail_count=$((fail_count + gfail))

    if [ "$exit_code" -ne 0 ] && [ "$gfail" -eq 0 ]; then
        echo "   ${RED}CRASHED${NC} test_${group}.sh exited $exit_code with no FAIL line — see output above"
        fail_count=$((fail_count + 1))
    fi
}

# Decide which groups to run
arg="${1:-quick}"
run_scripts=true
run_patch=true
run_build=true
run_e2e=true

case "$arg" in
    quick)   run_e2e=false ;;
    e2e)     run_scripts=false; run_patch=false; run_build=false ;;
    scripts) run_patch=false; run_build=false; run_e2e=false ;;
    patch)   run_scripts=false; run_build=false; run_e2e=false ;;
    build)   run_scripts=false; run_patch=false; run_e2e=false ;;
    all)     ;; # run everything
    *)       echo "Unknown arg '$arg', running all";;
esac

echo -e "${CYAN}==========================================================${NC}"
echo -e "${CYAN}  condabrew test suite   (arg=$arg, $(date '+%Y-%m-%d %H:%M'))${NC}"
echo -e "${CYAN}==========================================================${NC}"

$run_scripts && run_group scripts || true
$run_patch && run_group patch || true
$run_build && run_group build || true
$run_e2e && run_group e2e || true

echo ""
echo -e "${CYAN}==========================================================${NC}"
echo -e "  ${GREEN}SUMMARY${NC}: $pass_count passed, $fail_count failed, $skip_count skipped"
echo -e "${CYAN}==========================================================${NC}"

if [ "$fail_count" -gt 0 ]; then
    exit 1
fi
exit 0
