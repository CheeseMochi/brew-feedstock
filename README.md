About brew-feedstock
===========================

Feedstock license: [BSD-3-Clause](https://github.com/CheeseMochi/brew-feedstock/blob/main/LICENSE.txt)

Home: https://github.com/Homebrew/brew/

Package license: [BSD-2-Clause](https://github.com/Homebrew/brew/blob/main/LICENSE.txt)

Summary: Homebrew in a conda environment

Documentation: https://brew.sh/

**Homebrew inside a conda environment.** A `brew` CLI whose artifacts live only within the active conda env, scoped per-environment, isolated from the system.

This work is not associated with, the responsibility of, or the work of Homebrew and its maintainers. This is an independent work aimed at bringing the magic of Homebrew to a conda environment. Please forward all bugs and issues in this implementation to the feedstock maintaners.

## Why

macOS has no native package manager other than the App Store. Homebrew filled that gap, but it has three drawbacks for development workflows:

- **System-wide installs** — everything goes under `/opt/homebrew`, shared across users and environments.
- **No virtual env support** — you can only have one version of each dependency, available everywhere.
- **Hard to clean up** — uninstalling brew leaves remnants scattered across the filesystem.

This feedstock solves this by shipping a fully functional `brew` CLI inside a conda package. When you `conda activate` an environment, `brew` works normally but installs only into that environment's prefix. Deactivate and it disappears.

## How It Works

```
$CONDA_PREFIX/
  bin/brew                     ← Symlink to homebrew/bin/brew (always on PATH)
  homebrew/                    ← All other brew artefacts live here
    bin/brew                   ← The brew CLI
    Library/Homebrew/          ← Homebrew's Ruby code (patched)
    Library/Homebrew/vendor/   ← Portable Ruby metadata (Ruby itself comes from conda)
    Cellar/                    ← Installed formulae
    opt/                       ← Latest-version symlinks
    share/{zsh,fish,bash}/     ← Shell completions
```

Only the `brew` CLI itself is symlinked into `$CONDA_PREFIX/bin` (to avoid shadowing conda packages with conflicting versions/names); everything a formula installs stays under `homebrew/`.

**Path rewriting.** Homebrew computes its prefix by inspecting the binary location (`$PREFIX/homebrew/bin/brew` → `$PREFIX/homebrew`), but only fully resolves that through a symlink hop for `HOMEBREW_REPOSITORY` — not `HOMEBREW_PREFIX`, which stock `bin/brew` derives from `$0`'s literal (unresolved) path. Since only `brew` itself is symlinked into `$CONDA_PREFIX/bin` (see below), that left `HOMEBREW_PREFIX` one directory too shallow (`$CONDA_PREFIX` instead of `$CONDA_PREFIX/homebrew`), causing `brew link` to place formula binaries into the conda env's shared `bin/` instead of `homebrew/bin/`. The shipped patch fixes `bin/brew` to align `HOMEBREW_PREFIX` with the resolved repository, and separately relaxes bottle relocation checks so bottles built for the stock macOS prefixes (`/opt/homebrew` on ARM, `/usr/local` on Intel) get rewritten to `$CONDA_PREFIX/homebrew` at install time — no rebuild from source needed.

**Activation hooks.** On `conda activate`, PATH gets `$CONDA_PREFIX/homebrew/{bin,sbin}` inserted right after `$CONDA_PREFIX/bin`, and `HOMEBREW_*` env vars are set. On `conda deactivate`, everything is cleaned up.

**Package collisions.** If a formula you `brew install` provides a binary with the same name as a conda-installed package, both aren't reconciled automatically — whichever comes first on PATH wins. The only mitigation currently in place is that only the `brew` CLI itself is symlinked into `$CONDA_PREFIX/bin`; everything else stays under `homebrew/`, reducing (not eliminating) the chance of a collision. A more complete conda/Homebrew integration is a separate, larger project.

## Installation

### From anaconda.org

```bash
conda config --add channels <brew_conda_channel>
conda config --set channel_priority strict
conda create -n brew-env brew
conda activate brew-env
brew --version
```

(No package has been published yet — `<brew_conda_channel>` is a placeholder until a release channel exists. See "CI / Releases" below.)

### Build from source

Requires: macOS, an environment with `conda-build` installed, git, bash 4+.

```bash
cd brew-feedstock/     # project root contains the recipe/ subdir
conda-build -c conda-forge recipe/

# Install the built package. Build output goes to the *active* environment's
# own conda-bld/ (not the base install) -- $CONDA_PREFIX reflects whichever
# env you have conda-build installed and activated in.
CONDA_BUILT=$(find "$CONDA_PREFIX/conda-bld" -name "brew-*.conda" -o -name "brew-*.tar.bz2" | head -1)
conda create -n brew-test -c local "$CONDA_BUILT"
conda activate brew-test
```

## Usage

Once activated, `brew` works like normal — just scoped to the env.

```bash
conda activate brew-env

brew --version          # Shows version + prefix = $CONDA_PREFIX/homebrew
brew --prefix           # $CONDA_PREFIX/homebrew
brew install hello      # Installs into $CONDA_PREFIX/homebrew/Cellar/
hello                   # Runs from the env
brew doctor             # Validates setup

conda deactivate        # brew is no longer on PATH
which brew              # "not found"
```

## Updating the recipe version

1. Update `recipe/meta.yaml`: `package.version`, `source.url` + `source.sha256`, and the
   `brew-<version>/LICENSE.txt` version prefix in `about.license_file`
2. Update `recipe/build.sh`: change the `BREW_VERSION="..."` line to match
3. Increment `build.number` (reset to `0` when the version increases)

See `AGENTS.md` for the full details, plus what each file in `recipe/` does.

## CI / Releases

No CI is currently wired up (the previous workflow was stale and has been removed). Building and publishing a new version is a manual `conda-build` + upload for now.

## Limitations

- **macOS only** — both Apple Silicon (`/opt/homebrew`-built bottles) and Intel (`/usr/local`-built bottles) are handled by the relocation patch.
- **`brew update` is dangerous** — it replaces the patched brew binary. Update via reinstalling the conda package instead.
- **Some bottles may not relocate cleanly** — formulae with embedded absolute paths in non-standard locations (pkg-config, config files) may need source builds.
- **No automatic collision handling** between conda- and brew-installed packages of the same name (see "Package collisions" above).

## Terminology

**feedstock** - the conda recipe (raw material), supporting scripts and CI configuration.

**conda-forge** - the community channel/build infrastructure this terminology is borrowed from. This project isn't hosted on conda-forge itself, just uses the same "feedstock" naming convention.

## Feedstock Maintainers

* [@cheesemochi](https://github.com/CheeseMochi)
