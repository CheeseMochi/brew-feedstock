# Tests

Automated test suite for brew in a conda environment. Validates shell scripts, the patch file, build output, and full end-to-end brew workflow.

## Quick start

```bash
cd brew-feedstock/               # project root (where recipe/ dir lives)
bash tests/run.sh           # all quick tests + e2e
bash tests/run.sh quick     # script/patch/build only (fastest)
bash tests/run.sh e2e       # full pipeline: build → install → brew test
```

## Structure

| File | What |
|------|------|
| `run.sh` | Orchestrator — runs all groups, reports PASS/FAIL summary |
| `test_scripts.sh` | Validates activate/deactivate/post-link with mock `$CONDA_PREFIX` |
| `test_patch.sh` | Clones brew source, dry-runs `patch --dryrun`, diffs changed files |
| `test_build.sh` | Runs `conda-build -c conda-forge recipe/`, extracts the `.conda` artifact, checks paths |
| `test_e2e.sh` | Full pipeline: build → install in temp env → `brew install hello` (bottle check) → `brew install sqlite` + `otool -L` (proves the relocation patch actually rewrote paths) → deactivation cleanup |

## Prerequisites

- macOS (with brew source cloneable)
- The `condabrew` conda environment with `conda-build` installed. Create it from the repo's `environment.yml`:
  ```bash
  conda env create -f environment.yml
  conda activate condabrew
  ```
  Or manually:
  ```bash
  conda create -n condabrew python
  conda activate condabrew
  conda install -c conda-forge conda-build pyyaml
  ```

## Running

Activate the `condabrew` env first — the scripts call `conda-build`/`python3` directly and assume they're already on `PATH`, rather than wrapping each command in `conda run -n condabrew` (which double-resolves the env path when invoked from inside an already-active `condabrew`).

```bash
conda activate condabrew

# All tests (fast + slow)
bash tests/run.sh

# Filtered
bash tests/run.sh quick     # scripts + patch + build
bash tests/run.sh e2e       # full end-to-end
bash tests/run.sh scripts   # just script validation
bash tests/run.sh patch     # just patch dry-run
```

## CI Integration

No CI is currently wired up for this repo (see `AGENTS.md`/root `README.md`). Whenever one is added,
it should run this suite, e.g.:

```yaml
- name: Run test suite
  run: |
    cd $GITHUB_WORKSPACE/brew-feedstock
    bash tests/run.sh quick   # or 'all' for full pipeline
```
