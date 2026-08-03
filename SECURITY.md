# Security Policy

## Reporting a Vulnerability

Please **do not** open a public issue for security vulnerabilities.

Instead, use GitHub's private reporting: go to the [Security tab](../../security/advisories/new) of this repository and click "Report a vulnerability." This opens a private advisory visible only to the maintainer, so the issue can be reviewed and fixed before public disclosure.

You should expect an initial response within a few days. If the issue is confirmed, a fix will be prepared and a security advisory published once a patch is available.

## Scope

This repository ships a conda recipe and supporting shell scripts that package the upstream [Homebrew](https://github.com/Homebrew/brew) `brew` CLI for use inside a conda environment. Vulnerabilities in Homebrew itself should be reported upstream to the [Homebrew project](https://github.com/Homebrew/brew/security). This policy covers issues specific to this feedstock: the packaging, patch, build, and activation/deactivation scripts.
