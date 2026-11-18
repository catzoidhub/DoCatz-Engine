# Contributing to DoCatz Engine

Thank you for wanting to help — DoCatz is made by one person, with two others helping, and every fix, idea and bug
report counts. This page says how to get a change merged without wasted work.

## Before you start

- **Small fixes** (a typo, an obvious bug, a clearer message): open a pull request straight away.
- **Anything bigger** (a new feature, a new dependency, a change in how something works): open an issue first and
  wait for a yes, so nobody builds something that will not be merged.
- **Anything that changes [`docs/CONTRACT.md`](docs/CONTRACT.md)** — what DoCatz relies on — needs an issue first
  and a matching change in DoCatz.
- **Security problems** never go in a public issue or pull request — see [`SECURITY.md`](SECURITY.md).
- Questions and where to ask them: [`SUPPORT.md`](SUPPORT.md).

## Building it

You need a Mac with macOS 13 or later, the Xcode command line tools (Swift), Go and a Docker engine (DoCatz itself
works).

```sh
sh vmm/build.sh                 # out/docatz-vmm-<arch>, signed ad hoc with the virtualization entitlement
sh guest/build.sh arm64         # out/guest-arm64/: vmlinux, initramfs.img, rootfs.img, guest.json
sh scripts/package.sh           # out/release/: the archives, manifest.json, SHA256SUMS
```

The guest is built in an Alpine container of the guest's own architecture, because Alpine's package scripts run while
the root file system is made. On an Apple silicon Mac build `arm64`; the `x86_64` guest is built on an x86_64 machine
(the CI does both).

Releases (maintainer): a `v<version>` tag builds everything and drafts the release; `docatz-vmm` is signed with
Developer ID when the `MAC_CERT_P12` / `MAC_CERT_PASSWORD` secrets are set. Notarization runs in CI only with an App
Store Connect API key (`APPLE_API_KEY_P8` base64, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER`); otherwise run
`sh scripts/notarize.sh <version>` on a Mac with the `mrcatz-notary` notarytool profile — it changes no file, so the
published SHA-256s stay valid.

To try a VM by hand, write a `config.json` as in the contract (§4) and run
`out/docatz-vmm-arm64 run --config config.json`; `docatz-vmm ctl --socket <vmm.sock> status` talks to it.

## Making the change

- **Branches.** Work on a branch in your fork (`fix/…` or `feature/…`) and open the pull request against `main`.
  Releases are tags (`v0.2.0`).
- **Match the code around you** — its naming, comment style and structure. No reformatting of lines you did not
  change, and no new dependency without asking first. The guest stays small: a package added to the root file system
  needs a reason.
- **One change per pull request**, with a title that says what it does. Say why in the description and link the
  issue (`Fixes #123`).
- **Never commit secrets** — keys, tokens, passwords.

## Before you open the pull request

- `sh vmm/build.sh` and `cd agent && GOOS=linux go vet ./...` pass.
- Boot a VM with your change and run a container through its Docker socket.

## The contributor licence agreement

The first time you open a pull request, the CLA check asks you to sign the
[contributor licence agreement](CLA.md) by leaving a comment. You keep the copyright of your work; the agreement lets
the project ship it under its licence. You sign once for all your pull requests.

## Names and logos

DoCatz Engine's code is free software ([`LICENSE`](LICENSE)); its name, the DoCatz and Catzoid names and the cat logos
are not ([`TRADEMARKS.md`](TRADEMARKS.md)). A fork that is shared with others needs its own name.
