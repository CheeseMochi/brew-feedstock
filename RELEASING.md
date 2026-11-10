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
3. Pushes those changes to a branch per `X.Y` series, `bot/bump-brew-<X.Y>` (e.g.
   `bot/bump-brew-7.0`), and opens (or updates, if already open) a PR from it. A patch
   release (`7.0.12` -> `7.0.13`) landing before that PR is merged updates it, so
   in-between patch releases are skipped. A new series (`7.0` -> `7.1`, `7.x` -> `8.0`)
   gets a separate PR, so an unmerged series is never replaced. If the open PR already has this exact bump on top of current `main`, the run
   stops here, so nothing is re-pushed and CI isn't re-run. The bot **won't** overwrite
   that branch if its last commit wasn't made by the bot itself (e.g. a maintainer pushed
   patch-rework commits there) — it leaves a comment on the PR instead and waits for a
   human to reconcile it. With no open PR to comment on, it raises a `::warning::` on the
   workflow run.
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

This isn't hypothetical, and it has now happened twice. While writing this automation, a
dry-run of the then-current patch against brew `6.0.15` failed outright — one hunk in
`formula_installer.rb` no longer matched. Going from `5.1.15` to `6.0.20` then needed all
four hunks regenerated, because Homebrew 6.x restructured `formula_installer.rb`'s
relocation call and `keg_relocate.rb`'s `relocate_build_prefix`. Expect a major-version
bump PR to fail `quick`/`e2e` — treat it as a prompt to do the patch rework (Runbook B
below), not something to merge as-is.

**Every version-bump PR needs a human to actually read the `e2e` job's relocation-check
output**, not just glance at a green checkmark: does `sqlite`'s installed dylib really have
no `/opt/homebrew`/`/usr/local` references left (step 3b), and did `openssl@3` pour without
aborting on the build-prefix size mismatch (step 3c)? See Runbook A step 1 for what to look
for.

## Cutting a release

Two runbooks: the bump PR is green, or it isn't. Both end in the same place — a `vX.Y.Z`
tag pushed to `main`, with `release.yml` publishing to anaconda.org.

Everything below assumes:

```bash
cd ~/coding/brew-feedstock
conda activate condabrew    # every tests/run.sh and conda-build call needs this
```

`gh` commands have a web-UI equivalent if you'd rather click.

Both runbooks use `$branch` for the bump PR's head branch:

```bash
branch=bot/bump-brew-7.0    # the series the PR bumps to
```

**If more than one bump PR is open, handle them oldest series first.** Each one is based on
`main`, so merging `7.0` after `7.1` would downgrade brew. Once the older one merges, the
bot rebases the newer one onto `main` on its next daily run.

### Runbook A — the bump PR is green

**1. Read the e2e output, don't just trust the checkmark.** This is the whole reason there's
no auto-merge.

```bash
gh pr checks "$branch"
gh run list --workflow=e2e.yml --branch "$branch" --limit 1
gh run view <run-id> --log | grep -E '   (PASS|FAIL|WARN)'
```

What actually needs eyes, beyond "no FAIL lines":

- **Step 3b (sqlite)** — no leftover `/opt/homebrew` or `/usr/local` in the installed dylib.
- **Step 3c (openssl@3)** — the install *completed* rather than aborting on the build-prefix
  size mismatch, and the `OPENSSLDIR still /opt/homebrew/etc/openssl@3` line is a **WARN**.
  That WARN is the known limitation pinned as an assertion (see AGENTS.md's Constraints); a
  FAIL there means the rewrite corrupted the path instead of skipping it.
- Any `built from SOURCE` warning — the bottle path is what the patch exists to exercise, so
  a source build means the run proved much less than it looks like it did.

**2. Reproduce locally (optional, but it's the same suite CI ran):**

```bash
git fetch origin "$branch" && git checkout "$branch"
bash tests/run.sh all
```

**3. Merge, and delete the branch:**

```bash
git checkout main
gh pr merge "$branch" --squash --delete-branch
```

Deleting matters. `version-check.yml` refuses to force-push a bump branch if its last commit
wasn't the bot's own — so leaving a merged branch behind (especially one carrying your patch-rework
commits) blocks the next automated bump in that series and turns it into a warning instead.

**4. Confirm the three version sites agree, then tag:**

```bash
git checkout main && git pull
grep -m1 '{% set version' recipe/meta.yaml    # X.Y.Z
grep -m1 'BREW_VERSION='  recipe/build.sh     # must match
grep -n  'number:'        recipe/meta.yaml    # 0 on a version bump
```

`release.yml` re-checks the first two and refuses to publish on a mismatch; `build.number` it
doesn't check, so that one is on you.

```bash
git tag v6.0.20
git push origin v6.0.20
```

**5. Watch the release build:**

```bash
gh run watch "$(gh run list --workflow=release.yml --limit 1 --json databaseId -q '.[0].databaseId')"
```

`release.yml` re-verifies the tag against the recipe, reruns `tests/run.sh all` from scratch
against the tagged commit, uploads the `.conda` to the `cheesemochi` channel, and cuts a GitHub
Release. A green run here is independent of whatever CI ran on the PR.

**6. Verify it's actually installable.** A green `release.yml` means the upload succeeded, not
that your machine can see it — conda caches channel repodata, and a stale cache silently resolves
to an older build with no error and no version pin to stop it. (That is not hypothetical: a cache
from six weeks earlier once installed `brew-5.1.11-5`, one build shy of a fix, and the resulting
bug looked exactly like a patch regression.)

```bash
curl -s https://api.anaconda.org/package/cheesemochi/brew \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["latest_version"])'

conda clean --index-cache -y
conda search -c cheesemochi --override-channels brew
```

Then a throwaway smoke install, pinned to the version you just published:

```bash
conda create -n brewsmoke -c cheesemochi brew=6.0.20 -y
conda activate brewsmoke
brew --version && brew install openssl@3
conda deactivate && conda env remove -n brewsmoke -y
```

`openssl@3` rather than `hello`: it's the formula that exercises the build-prefix skip path, and
the one that broke in the field.

### Runbook B — the bump PR is red

**There is nothing to download from CI.** `test.yml` and `e2e.yml` upload no artifacts — the
failure reproduces locally from the branch, and that's the intended path.

**1. Get the branch and the version it's bumping to:**

```bash
git fetch origin "$branch" && git checkout "$branch"
version=$(grep -m1 '{% set version' recipe/meta.yaml | sed -E 's/.*"([^"]+)".*/\1/')
echo "$version"
```

**2. Find which layer broke, cheapest first:**

```bash
bash tests/run.sh patch    # clone + dry-run apply only — seconds, no build
bash tests/run.sh quick    # + scripts + a real conda-build
bash tests/run.sh e2e      # + install into a temp env and pour real bottles
```

A failure in `patch` means hunks stopped matching (the common case on a brew major bump). A
failure only in `e2e` means the patch applied but no longer does the right thing — the more
serious of the two, and exactly what the no-auto-merge rule exists to catch.

**3. Rework the patch against the new brew source:**

```bash
cd "${TMPDIR:-/tmp}"
git clone --depth 1 --branch "$version" https://github.com/Homebrew/brew.git "brew-$version"
cd "brew-$version"
patch -p1 --forward < ~/coding/brew-feedstock/recipe/conda-brew-path-rewrite.patch
```

Read each `.rej`, hand-edit the four targets — `Library/Homebrew/bottle_specification.rb`,
`formula_installer.rb`, `keg_relocate.rb`, `bin/brew` — then regenerate:

```bash
find . \( -name '*.rej' -o -name '*.orig' \) -delete
git diff HEAD > ~/coding/brew-feedstock/recipe/conda-brew-path-rewrite.patch
```

`git diff HEAD`, not `git diff`: it captures staged and unstaged edits both, so a stray `git add`
doesn't hand you an empty patch. Clearing the `.rej`/`.orig` files first keeps the next apply
attempt readable — they're untracked, so they never reach the patch either way.

The rework has to preserve six behaviors. Five are asserted by `tests/run.sh patch` and
`build`; the sixth is on you to eyeball, so read the regenerated diff before committing it:

| File | Must still | Asserted? |
|---|---|:--:|
| `bottle_specification.rb` | `compatible_locations?` returns `true` unconditionally | yes |
| `formula_installer.rb` | force `skip_linkage = false` | yes |
| `keg_relocate.rb` | add the `/opt/homebrew` + `/usr/local` replacement pairs | yes |
| `keg_relocate.rb` | add them **additively** — the original `:repository` pair stays | **no** |
| `keg_relocate.rb` | downgrade the size-mismatch `raise` to `opoo` + `next` | yes |
| `bin/brew` | `HOMEBREW_PREFIX="${HOMEBREW_REPOSITORY}"` after symlink resolution | yes |

The unasserted one has bitten this recipe before — an earlier revision of the patch dropped
`add_replacement_pair(:repository, ...)` entirely (see AGENTS.md's Patch section). Tests would
not catch a repeat.

**4. Re-test from the repo:**

```bash
cd ~/coding/brew-feedstock
bash tests/run.sh patch && bash tests/run.sh quick && bash tests/run.sh e2e
```

**5. Push the fix to the bot's branch:**

```bash
git add recipe/conda-brew-path-rewrite.patch
git commit -m "Rework path-rewrite patch for brew $version"
git push origin "$branch"
```

Two consequences of pushing there as a human:

- `test.yml` and `e2e.yml` fire **automatically** — your push isn't `GITHUB_TOKEN`-authored, so
  the anti-recursion restriction that forces the bot to `gh workflow run` doesn't apply. No
  manual dispatch needed.
- `version-check.yml` will now leave the branch alone (it checks the last commit's author). If
  brew releases again mid-rework you'll get a PR *comment*, not an updated PR — rebase onto the
  newer version by hand, or delete the branch to hand it back to automation.

**6. Once green, continue with Runbook A from step 1.**

### When a release itself goes wrong

What you can do depends entirely on whether anything reached the channel — the channel is
append-only, and a published version's tag must never move.

**`release.yml` failed *before* the "Upload to anaconda.org" step** — nothing was published, so
the tag is still yours to take back:

```bash
git push --delete origin v6.0.20
git tag -d v6.0.20
# land the fix on main, then re-tag
```

**It failed at/after the upload, or succeeded and the build was wrong** — that version is on the
channel forever. Bump `build.number` in `recipe/meta.yaml`, land it on `main`, and publish by
hand:

```bash
conda install -n condabrew -c conda-forge anaconda-client   # not in environment.yml
conda activate condabrew
bash tests/run.sh all
anaconda -t "$ANACONDA_API_TOKEN" upload -u cheesemochi \
  "$CONDA_PREFIX"/conda-bld/osx-arm64/brew-6.0.20-1.conda
```

`release.yml` can't do this one for you: its verify step compares `${GITHUB_REF_NAME#v}` against
`meta.yaml`'s version, so a `v6.0.20-1` tag fails the check outright. Teaching it to strip a
`-N` suffix is a small change if same-version rebuilds stop being rare.

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
python3 .github/scripts/bump_brew_version.py --version X.Y.Z
```

Rewrites `recipe/meta.yaml` and `recipe/build.sh` in place (version, `source.sha256`,
`build.number` reset to `0`) — the same thing `version-check.yml` runs, just aimed at a
version you pick. From there it's an ordinary branch: run `bash tests/run.sh all`, open a
PR by hand, and if the patch needs rework, follow Runbook B step 3 onward under "Cutting a
release" (using your branch name as `$branch`).
