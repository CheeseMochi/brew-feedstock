# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

See `AGENTS.md` for the canonical, detailed reference (build/test commands, patch internals, file-by-file
structure, constraints). This file adds only what AGENTS.md doesn't already cover.

## What this repo is

A conda recipe (`recipe/`) that packages upstream Homebrew's `brew` CLI so it installs and runs scoped to a
single conda environment (artifacts under `$CONDA_PREFIX/homebrew` instead of `/opt/homebrew` or `/usr/local`).
Package name in `recipe/meta.yaml` is `brew`; the dev/test conda env for *this repo* is `condabrew`
(`environment.yml`) — don't confuse the two.

## Quick start

```bash
conda env create -f environment.yml   # first time only
conda activate condabrew              # required before any conda-build/tests/run.sh invocation
bash tests/run.sh quick               # scripts + patch + build validation (fast)
bash tests/run.sh e2e                 # full pipeline: build → install → brew run → deactivate
```

## CI

`.github/workflows/test.yml` runs on push/PR to `main` (macOS runner, sets up the `condabrew` env, runs
`tests/run.sh quick`). Note: `AGENTS.md` and `README.md` both currently say "no CI is wired up" — that's
stale; the workflow exists. Don't propagate that claim, and consider updating those docs if you're touching
CI-adjacent files.

## Working on this repo — things that bite

- **Version bumps touch three places that must stay in sync**: `recipe/meta.yaml` (`package.version`,
  `source.url`/`sha256`, `about.license_file` prefix), `recipe/build.sh` (`BREW_VERSION`), and
  `recipe/meta.yaml`'s `build.number` (reset to 0 on a version bump). No CI computes `source.sha256` —
  do it manually (`curl -sL <url> | shasum -a 256`).
- **`post-link.sh` must use `$PREFIX`, never `$CONDA_PREFIX`** — link scripts don't get `$CONDA_PREFIX`
  reliably, and using it silently degrades every path to filesystem root instead of erroring.
- **`recipe/conda-brew-path-rewrite.patch` is the core logic.** It touches `bottle_specification.rb`,
  `formula_installer.rb`, and `keg_relocate.rb`; the `keg_relocate.rb` hunk adds `/opt/homebrew` and
  `/usr/local` replacement pairs *additively* alongside the original `:repository` pair — don't drop
  `:repository`. `build.sh` treats a failed patch apply as a hard build failure (by design — don't
  reintroduce silent skipping).
- **`patch` must be an explicit `requirements.build` dep** in `meta.yaml` — macOS's system `patch` is an
  old BSD version that silently skips unmatched hunks instead of failing.
- **Don't rely on `conda config --set plugins.use_sharded_repodata false`** to work around CEP-16 shard
  404s — `conda-build`'s solver calls don't reliably pick it up. Use the `CONDA_PLUGINS_USE_SHARDED_REPODATA=0`
  env var instead (already set in CI).
- **`brew update` is dangerous in this packaging** — it re-clones Homebrew's repo, undoing the shipped
  patch. `build.sh` disables auto-update via `etc/homebrew/brew.env`; don't remove that.
