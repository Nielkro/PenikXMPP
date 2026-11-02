# Tor dependency update — 2026-09-12

## Scope

Update Tor 0.4.9.8 to stable 0.4.9.12, released on 2026-09-08.
Lyrebird 0.8.1 is still the latest tagged stable release and is unchanged.
This changes packaging inputs, not Tor routing, account settings, MUJI or 1:1 calls.

Official references:

- https://forum.torproject.org/t/security-release-0-4-9-12/22096
- https://support.torproject.org/little-t-tor/getting-started/verifying/
- https://packages.msys2.org/packages/mingw-w64-x86_64-tor
- https://gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird/-/tags/lyrebird-0.8.1

## Artifact provenance

Both archives were downloaded from their upstream HTTPS distribution, verified,
uploaded under new names to the existing Forgejo `vendor-deps` release, and
downloaded again from Forgejo to compare their SHA-256 values. Older assets remain.

| Artifact | SHA-256 |
| --- | --- |
| `tor-0.4.9.12.tar.gz` | `c0d307c9dcdaee4848a8ca53e9d6c4ec92823e4f30be12790b0fbddfc6515f5b` |
| `mingw-w64-x86_64-tor-0.4.9.12-1-any.pkg.tar.zst` | `5f49afe442e00f0fa5c74f028cc8fa80ae46a1ab8c785f4d90982aae0b93f3e2` |

Tor's detached signature covers its `.sha256sum` file. Both signatures verified
against the signers listed by the Tor Project: David Goulet's
`B74417EDDF22AC9F9E90F49142E86A2A11F48D36` and Alexander Faeroy's signing subkey
`514102454D0A87DB0767A1EBBE6A0531C18A9179`.
The Windows package signature verified against the official MSYS2 keyring,
signer `5F944B027F7FE2091985AA2EFA11531AA0AA7F57` (Christoph Reiter).
The upstream signature files and checksum sidecars are mirrored alongside the archives.

## Validation and remaining gates

- Shell syntax, Windows distribution self-tests and `git diff --check` passed.
- Flatpak manifest runtime matrix: 64 OK, no warnings or failures.
- Independent review found consistent version, archive, signature and license pins.
- Tor compiled locally with the client-only packaging options and two build jobs.
  Its version is 0.4.9.12, dynamic libraries resolve, and an offline configuration
  check with `DisableNetwork=1` passed. No application account or Tor route changed.
- This is not a fresh DinoX package installation, Windows runtime test or Tor
  network bootstrap test. The reported Tor-enable problem remains separate.

Pushing the dependency scripts starts the existing Linux package-builder workflow.
Its image verification and automatic digest-pin commit must finish before starting
Linux package jobs or creating a product release tag. The previous builder image
correctly rejects the new dependency-script hashes; do not bypass that guard or
manually pin an unverified image. No product release is created by this update.
