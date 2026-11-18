# DoCatz Engine

The lightweight Docker engine behind DoCatz's **Lite** mode on macOS: `docatz-vmm`, a small VM helper on Apple's
Virtualization.framework, and the Linux guest it boots — Alpine's kernel, a read-only root file system with Docker
Engine, and `docatz-agent`. [DoCatz](https://github.com/catzoidhub/DoCatz) downloads both, pinned by SHA-256, when you
pick Lite in Settings → Engine; you do not install anything from here yourself.

- **Fast to wake** — a ready Docker about 2.5 s after the VM starts (Apple silicon), and the VM's state can be saved
  and restored (macOS 14+).
- **Your folders at the same paths** — your home folder is shared over virtiofs and mounted at the same path in the
  VM, so `-v ~/site:/app` works as on your Mac, with file events for hot reload.
- **Ports on localhost** — every port a container publishes is on `127.0.0.1` and `::1`.
- **amd64 images on Apple silicon** through Rosetta.
- **No SSH, no extra daemons** — the Docker socket, ports and control all go over vsock.

Status: **beta**, macOS 13+ (Apple silicon and Intel). Windows keeps WSL2 and Linux runs Docker directly; neither
uses this repository.

## How it fits together

```
DoCatz ──(engine helper)── docatz-vmm ─┬─ ~/.docatz/run/docker.sock ──vsock 2375──► docatz-agent ─► dockerd
                                       ├─ 127.0.0.1:<port> ──────────vsock 2376──► docatz-agent ─► the port in the VM
                                       ├─ vmm.sock (control, JSON lines)  ◄─vsock 2377── docatz-agent (events, ops)
                                       └─ virtiofs: your home folder, Rosetta
```

What DoCatz may rely on — the command line, the control socket, the release files — is written down in
[`docs/CONTRACT.md`](docs/CONTRACT.md).

| Folder | What |
| --- | --- |
| `vmm/` | `docatz-vmm` (Swift) |
| `agent/` | `docatz-agent` (Go), PID 1 in the guest |
| `guest/` | the guest's build: `initramfs/init`, `rootfs/` files, `build.sh`, licences, the kernel's source |
| `scripts/` | packing a release |
| `bench/` | measuring engines on one Mac (results stay internal) |

Building it yourself: see [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Licence

DoCatz Engine is free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License as published by the Free Software Foundation, version 3. It comes with no warranty. See
[`LICENSE`](LICENSE).

The guest also carries other people's software under their own licences — the Linux kernel (GPL-2.0, its source is
on each release), Docker Engine, containerd and runc (Apache-2.0) and Alpine Linux's packages; each guest lists them in
its `THIRD-PARTY.md`.

The names Catzoid, DoCatz and DoCatz Engine and the Catzoid cat are trademarks and are **not** covered by the licence:
a fork must use its own name and icon. See [`TRADEMARKS.md`](TRADEMARKS.md).

Contributions are welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md). Before your first pull request is merged you
sign the [contributor licence agreement](CLA.md) through the CLA check on the pull request — you keep the copyright of
your work. Questions and bug reports: [`SUPPORT.md`](SUPPORT.md); security problems, privately:
[`SECURITY.md`](SECURITY.md).

Copyright © 2026 Mahryan Rakhmatullah
