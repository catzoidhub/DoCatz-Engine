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
| UDP published ports | UDP on localhost | agent reports bound UDP sockets, vmm relays per client over vsock | ✅ |
| Domains `*.docatz.<tld>` and DBCatz's database ports | `docatz-router` (host network) on the VM's **127.0.0.1**:8790 and :<db port + 10000> reachable from the Mac | loopback listeners in the VM are forwarded too (as Lima does); checked through DoCatz's proxy (`https://<name>.docatz.localhost`, no port) | ✅ |
| Router reaching container IPs | the router container on the VM's host network | standard Docker bridge networking in the guest | ✅ |
| Bind mounts of project folders | `~` and `/tmp/docatz` at the same paths | virtiofs shares at the same paths (`shares`) | ✅ |
| Hot reload | inotify events for files changed on the Mac | `fsevents` (touch -c -m with the Mac's mtime) | ✅ |
| `host.docker.internal` from any container, `extra_hosts: …:host-gateway` (Sail, Postal, DevCatz's databases on the Mac's 127.0.0.1) | the name resolves in every network and reaches the Mac's loopback | `198.19.200.2` = the Mac's 127.0.0.1 / ::1 through the agent and vsock 2378; the agent's DNS (`198.19.200.3`) names it; `host-gateway-ip` the same (CONTRACT §7) | ✅ |
| `<name>.localhost` from a container (DevCatz's `rustfs.localhost`, `<name>.docatz.localhost`) | the name reaches the Catzoid proxies on the Mac's :443 | the agent's DNS answers every `*.localhost` with `198.19.200.2` (the Mac's loopback) | ✅ |
| amd64 images on Apple silicon | Rosetta | VZ Rosetta share + binfmt | ✅ |
| Engine settings: CPUs, memory | set at start | `cpus`, `memoryMiB` | ✅ |
| Engine settings: disk size | grow the disk | `disk --size-gib` grows the file, the guest grows ext4 at boot (16 → 32 GB, data kept) | ✅ |
| Reset | delete the VM's disk | delete `data.img` (+ `machine-id`, `mac`, state) | ✅ |
| Disk use shown, space back after prune | blocks in use of the disk file; trim | sparse `data.img`; `trim` | ✅ |
| Engine log | the VM manager's log | `console.log` (kernel, init, agent, dockerd) + `run`'s stderr | ✅ |
| Move from another Docker (#11), switching Standard ↔ Lite | both engines answering at once, on different sockets | Lite's socket is wherever `dockerSocket` points; Standard stays reachable at Lima's own `~/.docatz/vm/docatz/sock/docker.sock`; image and volume (mode, owner, symlink) moved both ways | ✅ |
| Image / volume export and import | the API (helper containers) | — (generic; the same save / load and tar pipes as Move) | ✅ |
| `docker` CLI and the `docatz` context | a stable socket path | `~/.docatz/run/docker.sock` | ✅ |
| Engine outlives the window, start at login (#107) | a process DoCatz's helper can own | `docatz-vmm run` as the helper's child; SIGTERM = clean stop | ✅ |
| Idle sleep, fast wake (#106) | stop or pause when idle, wake on the socket | `sleep`: the guest stops, docatz-vmm keeps the socket (12 MB), the first Docker call that needs dockerd boots it (`docker run` from sleep: 1.3 s); ping, version, info and `docker ps` are answered asleep. `save` / `restoreFrom` also works (wake 0.8 s) but brings all memory back resident | ✅ |
| Memory given back | unused guest memory returned to macOS | VZ's balloon does **not** return it (macOS 26.5, measured) and a restore makes it worse; only a stopped guest gives it back → `sleep` | ✅ |
| Clock after the Mac sleeps | guest time follows | `sync-time`, automatic on wake | ✅ |
| A guest kernel crash | the engine comes back by itself | guest reboots in place; open connections end; `restart` event | ✅ |
| Later: Kubernetes (#28), Linux machines (#27) as containers on the same dockerd | full `/lib/modules` (vxlan, ip_vs, br_netfilter, fuse, wireguard…), user namespaces, `/var/lib/docatz` on the data disk, `capabilities` in guest.json | all present | ✅ |
| Memory per running container | the container runtime's shim | containerd's Rust shim by default (0.6 MB vs 6.4 MB per container), OOM reported on cgroup v2 by our patch | ✅ |
| Intel Macs | the x86_64 build | docatz-vmm x86_64 + guest x86_64 (no Rosetta, no save / restore) | 🟡 |

Not engine features, nothing to do here: the proxy, CA, resolver and names without a port (DoCatz's own, on the Mac);
MCatzP; the window.
