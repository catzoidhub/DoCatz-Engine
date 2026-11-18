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

- Ports the VM listens on at 127.0.0.1 / ::1 are forwarded too (DoCatz's router: domains and DBCatz's database ports).
- A guest kernel crash no longer leaves a dead engine: `oops=panic panic=-1`, the guest reboots in place in about a
  second, open connections end, `state` reports `starting` with `restart` (rare oopses were seen in freshly loaded
  bridge / netfilter module code on an M4 under heavy memory pressure; the cause is still open).
- `init_on_alloc=0`: pages the balloon takes are no longer zeroed (they made the VM grow on the Mac).
- Intel build fixed (save / restore is Apple silicon only); the VM keeps its machine identity, so a saved state restores.
