# Security Policy

## Reporting a vulnerability

Please don't publish credentials, private data, or detailed exploit
instructions in a public issue.

If GitHub offers private vulnerability reporting for this repository, please
use it. Otherwise, contact `c0k0n` through [the GitHub
profile](https://github.com/c0k0n) with:

- the affected version,
- reproduction steps,
- possible impact, and
- safe supporting evidence.

## Scope

This script changes a system Go installation, edits shell configuration
files, and — with `--update` — replaces itself using downloads from this
project's GitHub releases. Downloads happen over HTTPS and are checked
against published checksums, so the whole chain — go.dev tarballs, checksum
files, the self-update path — is fair game for a report.

Please allow time for investigation before making a report public. Response
and fixes are handled on a best-effort basis, for the latest release.
