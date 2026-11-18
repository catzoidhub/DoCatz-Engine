# Security

DoCatz Engine is the lightweight engine of DoCatz's Lite mode: a VM helper on your computer, a Linux guest that mounts your home folder, and a Docker engine that runs images from the internet. A security problem in it is taken seriously.

## Reporting a vulnerability

**Please do not open a public issue.** Report it privately instead:

1. Open the repository's **Security** tab → **Report a vulnerability**
   ([direct link](https://github.com/catzoidhub/docatz-engine/security/advisories/new)). Only the maintainer sees it.
2. Say what is affected, how to reproduce it, and what an attacker could do with it. A proof of concept helps.

Security reports are read before anything else, as soon as the maintainer can — there is no fixed response time yet.
Together we agree on a fix and when to publish it; you are credited in the advisory and the release notes unless you
would rather not be.

## What is in scope

- The VM helper (`docatz-vmm`), the guest (kernel, root file system, agent) and the release files DoCatz downloads (pinned by SHA-256 in DoCatz).
- Anything that lets a container or the guest reach the host beyond what was shared, or another user or process on the host
  use the helper's control socket, the forwarded Docker socket or the published ports.
- Container escapes made possible by the kernel or container runtime we ship: these get a guest release of their own, without waiting for a DoCatz release.

Out of scope: problems that need someone who already controls your computer or your user account, and vulnerabilities in
third-party software in the guest (Alpine, the Linux kernel, Docker; report those upstream — we are happy to help), unless the way we build or ship it is the problem.

## Supported versions

Only the **latest release** gets security fixes; DoCatz downloads the guest that goes with it, so please keep DoCatz up to date.
