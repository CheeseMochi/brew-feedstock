#!/usr/bin/env python3
# Bumps recipe/meta.yaml + recipe/build.sh to a new Homebrew/brew version.
#
# Usage:
#   bump_brew_version.py                 # check Homebrew/brew's latest GitHub
#                                         # release, bump if newer than meta.yaml
#   bump_brew_version.py --version X.Y.Z # bump to an explicit version
#
# Writes bumped=true/false (and new_version=X.Y.Z) to $GITHUB_OUTPUT when set,
# so this doubles as the check used by .github/workflows/version-check.yml and
# a one-shot manual bump tool (see RELEASING.md).

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.request

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
META = os.path.join(REPO_ROOT, "recipe", "meta.yaml")
BUILD_SH = os.path.join(REPO_ROOT, "recipe", "build.sh")

VERSION_RE = re.compile(r'\{% set version = "([^"]+)" %\}')
SHA256_RE = re.compile(r"sha256: [0-9a-f]{64}")
BUILD_NUMBER_RE = re.compile(r"(number:\s*)\d+")
BREW_VERSION_RE = re.compile(r'BREW_VERSION="[^"]+"')


def current_version():
    with open(META) as f:
        text = f.read()
    m = VERSION_RE.search(text)
    if not m:
        sys.exit("could not find '{% set version = ... %}' in recipe/meta.yaml")
    return m.group(1)


def latest_release_tag():
    req = urllib.request.Request(
        "https://api.github.com/repos/Homebrew/brew/releases/latest",
        headers={"Accept": "application/vnd.github+json"},
    )
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)["tag_name"]


def sha256_of(url):
    h = hashlib.sha256()
    with urllib.request.urlopen(url) as resp:
        for chunk in iter(lambda: resp.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def bump(version):
    url = f"https://github.com/Homebrew/brew/archive/refs/tags/{version}.tar.gz"
    sha256 = sha256_of(url)

    with open(META) as f:
        meta = f.read()
    meta = VERSION_RE.sub(f'{{% set version = "{version}" %}}', meta, count=1)
    meta = SHA256_RE.sub(f"sha256: {sha256}", meta, count=1)
    meta = BUILD_NUMBER_RE.sub(r"\g<1>0", meta, count=1)
    with open(META, "w") as f:
        f.write(meta)

    with open(BUILD_SH) as f:
        build_sh = f.read()
    build_sh = BREW_VERSION_RE.sub(f'BREW_VERSION="{version}"', build_sh, count=1)
    with open(BUILD_SH, "w") as f:
        f.write(build_sh)


def write_output(**kv):
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a") as f:
        for k, v in kv.items():
            f.write(f"{k}={v}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--version", help="bump to this exact version instead of checking upstream"
    )
    args = parser.parse_args()

    old = current_version()
    new = args.version or latest_release_tag()

    if new == old:
        print(f"up to date: {old}")
        write_output(bumped="false")
        return

    print(f"bumping {old} -> {new}")
    bump(new)
    write_output(bumped="true", new_version=new, old_version=old)


if __name__ == "__main__":
    main()
