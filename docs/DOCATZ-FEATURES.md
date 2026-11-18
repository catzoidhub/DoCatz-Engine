# DoCatz features and what the engine gives them

Lite is allowed to be lighter, not to do less: every DoCatz feature that works on Standard (Lima) must work on Lite.
This list is what DoCatz does with its engine and how Lite provides it. Status: ✅ tested on Lite, 🟡 built not tested,
⬜ missing. Update it when DoCatz gains a feature that touches the engine.

| DoCatz feature | What it needs from the engine | Lite (docatz-vmm + guest) | Status |
| --- | --- | --- | --- |
| Containers, images, volumes, networks, logs, stats, events, prune | the Docker Engine API on the socket | dockerd 28 over vsock at `dockerSocket` | ✅ |
| Terminals (`docker exec`), attach | hijacked HTTP streams on the socket | the socket joins both ways with half-close | ✅ |
| Compose runs, builds (BuildKit / buildx) | the API + BuildKit | dockerd's built-in BuildKit (`features.buildkit`) | ✅ |
| Published ports on localhost | TCP on 127.0.0.1 / ::1 | agent reports listeners, vmm listens and forwards | ✅ |
| UDP published ports | UDP on localhost | — | ⬜ |
| Domains `*.docatz.<tld>` and DBCatz's database ports | `docatz-router` (host network) on the VM's **127.0.0.1**:8790 and :<db port + 10000> reachable from the Mac | loopback listeners in the VM are forwarded too (as Lima does); checked through DoCatz's proxy (`https://<name>.docatz.localhost`, no port) | ✅ |
| Router reaching container IPs | the router container on the VM's host network | standard Docker bridge networking in the guest | ✅ |
| Bind mounts of project folders | `~` and `/tmp/docatz` at the same paths | virtiofs shares at the same paths (`shares`) | ✅ |
| Hot reload | inotify events for files changed on the Mac | `fsevents` (touch -c -m with the Mac's mtime) | ✅ |
| `extra_hosts: …:host-gateway`, `host.docker.internal` (Sail, Postal…) | host-gateway = an address that reaches the Mac | `host-gateway-ip` = the NAT gateway | ✅ |
| amd64 images on Apple silicon | Rosetta | VZ Rosetta share + binfmt | ✅ |
| Engine settings: CPUs, memory | set at start | `cpus`, `memoryMiB` | ✅ |
| Engine settings: disk size | grow the disk | `disk --size-gib` grows the file, the guest grows ext4 at boot | 🟡 |
| Reset | delete the VM's disk | delete `data.img` (+ `machine-id`, `mac`, state) | 🟡 |
| Disk use shown, space back after prune | blocks in use of the disk file; trim | sparse `data.img`; `trim` | ✅ |
| Engine log | the VM manager's log | `console.log` (kernel, init, agent, dockerd) + `run`'s stderr | ✅ |
| Move from another Docker (#11), switching Standard ↔ Lite | both engines answering at once, on different sockets | Lite's socket is wherever `dockerSocket` points; Standard stays reachable at Lima's own `~/.docatz/vm/docatz/sock/docker.sock` | 🟡 |
| Image / volume export and import | the API (helper containers) | — (generic) | 🟡 |
| `docker` CLI and the `docatz` context | a stable socket path | `~/.docatz/run/docker.sock` | ✅ |
| Engine outlives the window, start at login (#107) | a process DoCatz's helper can own | `docatz-vmm run` as the helper's child; SIGTERM = clean stop | ✅ |
| Idle sleep, fast wake (#106) | stop or pause when idle, wake on the socket | `save` / `restoreFrom` (Apple silicon, macOS 14+) | 🟡 |
| Memory given back | unused guest memory returned to macOS | VZ's balloon does **not** return it (macOS 26.5, measured); save → restore does | 🟡 |
| Clock after the Mac sleeps | guest time follows | `sync-time`, automatic on wake | ✅ |
| A guest kernel crash | the engine comes back by itself | guest reboots in place; open connections end; `restart` event | ✅ |
| Intel Macs | the x86_64 build | docatz-vmm x86_64 + guest x86_64 (no Rosetta, no save / restore) | 🟡 |

Not engine features, nothing to do here: the proxy, CA, resolver and names without a port (DoCatz's own, on the Mac);
MCatzP; the window.
