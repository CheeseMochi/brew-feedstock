# Releasing

How this feedstock tracks new Homebrew (`brew`) releases, and how a version gets from
"Homebrew published it" to "installable via `conda install brew=X.Y.Z`".

## Versioning model: rolling latest, not concurrent versions

`recipe/` always targets a single version of `brew` — the newest one this feedstock has
validated — the same model conda-forge itself uses for standalone CLI tools (see
`ripgrep-feedstock`, `bat-feedstock`: one `{% set version = "X.Y.Z" %}`, `build.number`
reset to `0` on every version bump).

"Supporting" an older version doesn't mean maintaining it in the recipe. conda channels
are append-only — nothing is ever deleted from `cheesemochi`'s anaconda.org channel — so
once `brew=5.1.11` has been published, `conda install brew=5.1.11` keeps working forever,
even after `recipe/meta.yaml` has moved on to `6.0.15`. Every published version also gets
a matching git tag (`v5.1.11`, `v6.0.15`, ...), so the exact recipe state that produced
any given published build stays reproducible from git history alone — see "Reproducing a
past release" below.

This repo does **not** maintain multiple brew majors side by side the way, say,
conda-forge's `nodejs14`/`nodejs16`/`nodejs18` feedstocks do. That model exists because
projects pin exact Node majors as a hard runtime requirement; nothing about `brew`
usage works that way, and the path-rewrite patch (see `AGENTS.md`) already carries
real per-release maintenance cost — multiplying that across concurrently-maintained
majors isn't worth it for this project's scale.

## Automation

### `.github/workflows/version-check.yml` — detect + open a PR

Runs daily (`brew` releases every few days, sometimes more than once a week — weekly
would leave this chronically behind). It:

1. Checks Homebrew/brew's latest GitHub release tag against `recipe/meta.yaml`'s version.
2. If newer, runs `.github/scripts/bump_brew_version.py`, which rewrites `meta.yaml`
   (version, `source.sha256`, `build.number` reset to `0`) and `build.sh`'s
   `BREW_VERSION` in place.
3. Pushes those changes to a fixed branch, `bot/bump-brew`, and opens (or updates, if
   already open) a PR from it. Using a fixed branch name means a second release landing
   before the first bump PR is merged updates the same PR instead of piling up parallel
   ones. The bot **won't** overwrite that branch if its last commit wasn't made by the
   bot itself (e.g. a maintainer pushed patch-rework commits there) — it leaves a comment
   on the PR instead and waits for a human to reconcile it.
4. Explicitly triggers `test.yml` and `e2e.yml` against that branch via
   `gh workflow run ... --ref`. This step exists only because of a GitHub Actions
   restriction: pushes and PRs authored by the workflow's own `GITHUB_TOKEN` do not
   trigger other `push`/`pull_request`-triggered workflows (it's an anti-recursion
   guard). Without this explicit dispatch, a bot-opened PR would show zero CI checks.

### No auto-merge — and why that's not just caution for its own sake

conda-forge's own bot (`regro-cf-autotick-bot`) auto-merges version bumps once CI is
green. This feedstock deliberately doesn't, because `recipe/conda-brew-path-rewrite.patch`
patches three of Homebrew's own Ruby files directly (`bottle_specification.rb`,
`formula_installer.rb`, `keg_relocate.rb`) plus `bin/brew` — unlike a typical
build-from-source recipe, "the patch still applies" and "the patch still does the right
thing" are different claims, and only the second one is what actually matters.

This isn't hypothetical: while writing this automation, a dry-run of the current patch
against the (at-the-time) latest brew release, `6.0.15`, failed outright — one hunk in
`formula_installer.rb` no longer matched. `5.1.11` (this feedstock's currently-shipped
version) predates a Homebrew major version bump, and the patch has not been re-validated
against `6.x` yet. The bot will still open a PR bumping to whatever's newest, but expect
it to fail `quick`/`e2e` until the patch is reworked — treat that PR as a prompt to do
the patch rework, not something to merge as-is.

**Every version-bump PR needs a human to actually read the `e2e` job's relocation-check
output** (does `sqlite`'s installed dylib really have no `/opt/homebrew`/`/usr/local`
references left? see `tests/test_e2e.sh` step 3b), not just glance at a green checkmark,
before merging.

## Cutting a release

1. Merge the version-bump PR (bot-opened or manual) to `main`, once `quick` + `e2e` are
   green *and* you've read the e2e relocation-check output, not just its exit code.
2. Tag the merge commit `vX.Y.Z`, matching `recipe/meta.yaml`'s version exactly, and push
   the tag:
   ```bash
   git tag v6.0.15
   git push origin v6.0.15
   ```
3. `.github/workflows/release.yml` fires on that tag push:
   - Re-verifies the tag matches both `meta.yaml`'s version and `build.sh`'s
     `BREW_VERSION` (protects against a partially-applied manual edit slipping through).
   - Rebuilds from scratch and reruns `tests/run.sh all` as a final gate — independent of
     whatever CI ran against the PR, against the exact tagged commit.
   - Uploads the built `.conda` package to the `cheesemochi` anaconda.org channel.
   - Creates a GitHub Release linked to Homebrew's own release notes for that tag.
4. If the tagged build fails, don't force-push the tag to a fixed-up commit — delete it,
   land the fix on `main`, and re-tag. A published (channel-uploaded) version's tag should
   never move.

### One-time repo setup this automation needs

- **Settings → Actions → General → Workflow permissions**: enable "Allow GitHub Actions
  to create and approve pull requests." Without it, `version-check.yml`'s `gh pr create`
  call is rejected — this is a repo-level toggle, not something a workflow can turn on
  for itself.
- **Settings → Secrets and variables → Actions**: add `ANACONDA_API_TOKEN`, a token from
  anaconda.org scoped to upload to the `cheesemochi` channel. `release.yml` needs this;
  without it the build/test steps still run but the upload step fails.

## Reproducing a past release

Every published version has a matching `vX.Y.Z` tag, and the recipe files that produced
it (`meta.yaml`'s version/sha256, `build.sh`'s `BREW_VERSION`, the patch) are exactly
what's checked in at that commit:

```bash
git checkout v5.1.11
conda-build -c conda-forge recipe/
```

This reproduces the same source (pinned by `sha256`), the same patch, and the same build
script. It is **not** bit-for-bit reproducible in the strictest sense: `requirements.build`
(`git`, `bash`, `patch`) and `requirements.run` (`git >=2.30.0`) resolve against whatever
conda-forge currently has, not whatever was current at original publish time. Pinning
those exactly would need a `conda_build_config.yaml` variant/lockfile; not done today —
see Known limitations.

## Known limitations

- **osx-arm64 only, currently.** `release.yml` runs on `macos-latest` (Apple Silicon) and
  the recipe's own test tooling (`tests/test_build.sh`, `tests/test_e2e.sh`) looks for
  artifacts under `conda-bld/osx-arm64/` specifically. `skip: true  # [not osx]` in
  `meta.yaml` already excludes non-macOS entirely; within macOS, only arm64 is actually
  built and published today. An Intel (`osx-64`) build would need its own runner in the
  matrix — not wired up.
- **Build-dependency versions aren't pinned.** See "Reproducing a past release" above.
- **The patch is only checked against the version being bumped to, at bump time.** A
  Homebrew release *after* the one currently shipped could still change
  `bottle_specification.rb`/`formula_installer.rb`/`keg_relocate.rb`/`bin/brew` enough to
  silently change relocation behavior without failing the patch's `--dryrun` apply check
  (fuzz-matched hunks can land in a slightly different place than intended). CI applying
  cleanly is necessary, not sufficient — see "No auto-merge" above.

## Manual bump (automation down, or jumping ahead deliberately)

```bash
python3 .github/scripts/bump_brew_version.py --version 6.0.15
```

Rewrites `recipe/meta.yaml` and `recipe/build.sh` in place (version, sha256, build number
reset). Then run `bash tests/run.sh all` before opening a PR by hand.
