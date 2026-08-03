## repo: brew-feedstock — Homebrew packaged for conda environments

### Build & test

```bash
conda env create -f environment.yml             # first time: creates the condabrew env
conda activate condabrew                        # activate the project's test/build env first
conda-build -c conda-forge recipe/               # build conda package
bash tests/run.sh quick                         # default: scripts + patch + build (fast)
bash tests/run.sh e2e                           # full pipeline: build → install → brew run → deactivate
bash tests/run.sh all                           # everything including e2e
```

Tests assume `condabrew` is already the active conda env (activate it before running `tests/run.sh`) — they call `conda-build`/`python3` directly rather than wrapping each command in `conda run -n condabrew`, which double-resolves the env path when already inside it.

### Updating recipe version

1. Update `recipe/meta.yaml`: `package.version`, `source.url` + `source.sha256`, and the
   `brew-5.1.11/LICENSE.txt` version prefix in `about.license_file`
2. Update `recipe/build.sh`: change the `BREW_VERSION="5.1.11"` line to match (also pins the
   git-clone fallback's `--branch`, so it can't silently build against current master)
3. Increment `build.number` (reset to `0` when version increases)
4. There is no CI right now (see Constraints) — compute `source.sha256` manually,
   e.g. `curl -sL <source.url> | shasum -a 256`

### Patch (the core logic)

`recipe/conda-brew-path-rewrite.patch` rewrites brew's bottle relocation so bottles built for
`/opt/homebrew` or `/usr/local` install into `$CONDA_PREFIX/homebrew`. `build.sh` applies it to
the copy at `$PREFIX/homebrew` (not `$SRC_DIR`, which is build.sh's default cwd) and the build now
fails loudly if it doesn't apply cleanly. The patch touches three Ruby files:
- `Library/Homebrew/bottle_specification.rb` — relaxes `compatible_locations?`
- `Library/Homebrew/formula_installer.rb` — forces `skip_linkage = false`
- `Library/Homebrew/keg_relocate.rb` — adds `/opt/homebrew` and `/usr/local` as replacement pairs,
  additively alongside the original `:repository` pair (an earlier version of this patch dropped
  `:repository` entirely — don't reintroduce that)

### Structure

```
recipe/
  meta.yaml                    # conda recipe (package name: "brew", not "condabrew")
  build.sh                     # extracts source, applies patch, generates configs
  post-link.sh                 # mkdir required dirs + `brew doctor` (--warn-only was removed upstream)
  conda-brew-path-rewrite.patch
  etc/conda/
    activate.d/brew-activate.sh     # prepends $CONDA_PREFIX/homebrew/{bin,sbin} to PATH, sets HOMEBREW_* vars
    deactivate.d/brew-deactivate.sh # removes brew from PATH, unsets HOMEBREW_* vars
tests/
  run.sh                       # orchestrator
  test_scripts.sh              # validates activate/deactivate/post-link with mock $CONDA_PREFIX
  test_patch.sh                # clones brew source, dry-runs patch, diffs changes
  test_build.sh                # runs conda-build, extracts and validates the .conda artifact
  test_e2e.sh                  # build → install in temp env → brew install hello + sqlite →
                                # verify bottle used and relocation actually rewrote paths → deactivate
```

### Constraints

- macOS only (`skip: true  # [not osx]` in recipe)
- Ruby comes from conda (`ruby >=4.0,<4.1`), not bundled
- `brew update` is dangerous — it replaces the patched binary; reinstall the conda package instead
- Package name is `brew` (in meta.yaml), not `condabrew` — conflicting with system brew if both installed
- No CI is wired up currently (previous `.github/workflows/build.yml` was stale and was removed);
  builds/publishes are manual for now
- Collisions between conda-installed and brew-installed packages of the same name are not handled
  beyond the narrow mitigations already in place (only the `brew` CLI itself is symlinked into
  `$PREFIX/bin`; the activate/deactivate hooks use package-specific filenames). A broader
  conda/homebrew integration is a separate, bigger future project.
- `post-link.sh` runs as a conda link script and gets `$PREFIX` (the env being linked into) --
  *not* `$CONDA_PREFIX`, which is only set during activation. Don't use `$CONDA_PREFIX` in that
  file; it silently turns every path into a filesystem-root path with no error (the exact class
  of bug that already shipped once via `build.sh`'s dropped `|| true`).

### Key env path convention

All brew artifacts live under `$CONDA_PREFIX/homebrew`, not `/opt/homebrew` or `/usr/local`. The patch
rewrites bottle paths so standard macOS bottles (ARM `/opt/homebrew`, Intel `/usr/local`) work without
rebuilding from source.
