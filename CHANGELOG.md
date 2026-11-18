# Changelog

## 0.1.0

First release, for DoCatz's Lite engine (beta) on macOS.

- `docatz-vmm`: the VM on Virtualization.framework — virtiofs shares at the same paths, Rosetta for amd64 images,
  vsock for the Docker socket, published ports on 127.0.0.1 and ::1, a memory balloon, file events for hot reload,
  saving / restoring the VM's state (macOS 14+), a JSON-lines control socket (docs/CONTRACT.md, protocol 1).
- Guest: Alpine 3.22 with its `linux-virt` kernel 6.12, Docker Engine 28, a read-only root file system and a data
  disk made on first boot; `docatz-agent` as PID 1.
- Boots to a ready Docker in about 2.5 s on an Apple silicon Mac.

## Unreleased
