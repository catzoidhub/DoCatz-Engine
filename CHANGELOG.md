# Changelog

## 0.1.4

- Containers run under containerd's Rust shim by default (`runc-rs`): about 6 MB less per running container
  (20 containers: 674 MB instead of 786 MB for the VM). Our patch reports OOM kills on cgroup v2 (`OOMKilled`, the
  `oom` event), as dockerd's Go shim does; `--runtime runc` still picks that one. Capability `shim-rs`.
- Release tooling: `scripts/notarize.sh <version>` notarizes a published release's docatz-vmm on the maintainer's
  Mac (no file changes, so the SHA-256s stay); CI notarizes too once an App Store Connect API key is set.

## 0.1.3

- `docatz-vmm` is signed with Developer ID (Mahryan Rakhmatullah, Q5Q5KKYWU7), with the hardened runtime and a
  timestamp, instead of ad hoc. Nothing else changed.

## 0.1.2

- The guest's `/` is a shared mount from boot (as under systemd): `-v …:…:rshared` binds (k3s in a container) work
  with nothing done by DoCatz; capability `shared-mounts`.

## 0.1.1

- One docatz-vmm per VM: a second `run` on the same data disk exits 3 and names the running one (`vmm.lock`),
  instead of taking the first one's sockets and failing on its disk.

## 0.1.0

First release, for DoCatz's Lite engine (beta) on macOS 13+ (Apple silicon and Intel).

- `docatz-vmm`, the VM on Virtualization.framework: your folders over virtiofs at the same paths, Rosetta for amd64
  images, the Docker socket over vsock, published TCP and UDP ports on 127.0.0.1 and ::1 (ports the VM listens on at
  its loopback too, for DoCatz's router), file events for hot reload, a JSON-lines control socket
  (docs/CONTRACT.md, protocol 1).
- Fast: a ready Docker about 1 s after `run` on Apple silicon (a first boot, which formats the data disk, 0.9 s).
- Idle sleep: `sleep` stops the guest so its memory goes back to the Mac while docatz-vmm (about 10 MB) keeps the
  Docker socket; `docker ping / version / info / ps` are answered asleep, anything else wakes it (`docker run` from
  sleep: 1.3 s). `sleep` can refuse while the engine is in use (`maxConnections`).
- Guest: Alpine 3.22 with its `linux-virt` kernel 6.12 (all modules), Docker Engine 28, a read-only root under a
  tmpfs layer, a data disk made on first boot (Docker's data and `/var/lib/docatz`), `docatz-agent` as PID 1;
  `guest.json` lists its `capabilities`.
- A guest kernel crash reboots the guest in place in about a second instead of leaving a dead engine (rare oopses
  seen on an M4 under heavy memory pressure; the cause is still open).
- Known limits: Virtualization.framework's memory balloon returns nothing to macOS, so memory a running guest has
  touched is only given back by `sleep` or `stop`; save / restore works (Apple silicon, macOS 14+) but brings all
  memory back resident.
