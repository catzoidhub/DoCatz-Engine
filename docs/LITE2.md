# Lite 2: a daemon of our own? Design and decision

Status: **cancelled (user, 2026-11-18).** Lite exists to give users a lighter option than Standard; a daemon of our own
saves a bounded amount (below) at an unbounded cost, so it is not built — not deferred. The one idea kept is the
lighter shim (§3 D), as an ordinary change to Lite's guest if it measures lighter. On Linux, where Lite 2 was the only
planned path, Lite is "the system's Docker run as lightly as possible" (DoCatz TODO #106), never a VM: a VM there is
heavier than native dockerd while working.

The analysis below is kept as the reason.

"Lite 2" (DoCatz TODO #106) means replacing dockerd + containerd + one containerd-shim per container in the Lite guest
with one daemon of ours that answers the Docker Engine API and calls the kernel itself. It is the only way to the
lowest memory with many containers and to a `docker run` in tens of milliseconds.

## 1. What it would save (measured, v0.1.0 guest, 4 GB VM, Apple M4)

Memory inside the guest by process (anonymous memory; RSS in brackets):

| | 0 containers | 10 × nginx:alpine | + 10 × `busybox sleep` |
| --- | --- | --- | --- |
| dockerd | 28 MB (68) | 32 MB (73) | 37 MB (78) |
| containerd | 18 MB (40) | 22 MB (44) | 19 MB (42) |
| containerd-shim, each ~6.5 MB (13) | 6 MB, 1 (the router's) | 67 MB, 11 | 130 MB, 21 |
| docatz-agent | 6 MB | 6 MB | 8 MB |
| the containers' own processes | — | 90 MB (50 nginx processes) | 90 MB |
| page cache (mostly the three binaries) | 113 MB | 123 MB | 127 MB |
| **VM footprint on the Mac** | 468 MB | 613 MB | 696 MB |

So with our own daemon (say 15 MB, no shim, a small binary):

- fixed: about 50 MB of daemons + perhaps 80 MB of page cache → idle **~470 → ~330 MB**;
- per container: **6.5 MB** (13 MB RSS) less each → with 20 containers ~130 MB less.

Not saved by any daemon: the workload itself (nginx: 9 MB per container at 4 CPUs), the kernel and its struct pages
(~30 MB per GB of VM), memory the guest touched once (Virtualization.framework's balloon returns nothing).
A tighter Go collector (`GOGC=25` for dockerd, containerd and the shims) was tried: about 10 MB in all, shims
unchanged — not taken.

What Lite already has without it: asleep at 10 MB (the VM stopped, `docker ps` still answered), awake in about a
second. For a developer's Mac the idle state matters most, and that is solved.

## 2. What it would have to answer

DoCatz itself calls about 30 endpoints (`src/main/docker/*.ts`): `_ping`, `version`, `info`, `events`,
`containers/json|create|{id}/json|start|stop|restart|kill|pause|unpause|rename|logs|stats|archive (GET, PUT)|exec`,
`exec/{id}/start|resize|json`, `images/json|create|{id}`, `volumes`, `networks`, `system/df`, the five `prune`s.
That part is small.

But DoCatz, DevCatz and the user also run the **docker CLI, Compose and buildx** against the same socket, and those
decide the real surface:

- Compose: `containers/create` with the whole HostConfig / NetworkingConfig (healthchecks, depends_on through
  `wait` and `events`, restart policies, resource limits, capabilities, devices, tmpfs, secrets and configs as mounts),
  `attach` and `wait`, `networks/create|connect|disconnect` with aliases and container DNS, volumes with drivers and
  labels, `images/{id}/json`, `distribution`, `auth`.
- Builds: BuildKit over `/session` and `/grpc` (hijacked HTTP/2), buildx's history records (DoCatz's Builds page),
  the image store BuildKit writes into.
- The CLI's long tail: `commit`, `diff`, `export`, `import`, `save` / `load` (DoCatz's Move and image files),
  `top`, `update`, `cp` with its tar semantics, `system events` filters, `inspect` fields people script against,
  API version negotiation back to old clients.
- Under it: an OCI image store with pulls (registries, auth, mirrors, platforms, zstd layers), overlayfs snapshots,
  the bridge network with iptables / nftables NAT and published ports, an embedded DNS for container names, logging
  drivers (json-file with rotation), cgroups v2, seccomp / AppArmor defaults, user namespaces, healthchecks, restart
  managers, `init`, stats.

Every one of those has behaviour users rely on without knowing it ("as on Docker"). A product that took this road
publishes a long list of such fixes; that list is the real cost.

## 3. Options

| | What | Saves | Cost and risk |
| --- | --- | --- | --- |
| **A. Our own daemon** | everything in §2, in Go or Rust, runc / crun or libcontainer for the last step, BuildKit embedded or beside it | all of §1 | Largest: one maintainer, an unbounded compatibility tail, security-sensitive code (image pulls, namespaces, seccomp) that today is Docker's and audited. Many months before Compose projects "just work"; never finished |
| **B. Podman's API service** | `podman system service` + conmon (C, ~1 MB per container) + crun, from Alpine's packages | shims and most of the daemons; no always-on daemon at all | Its Docker API is close but not equal: no BuildKit (`docker buildx`, build history → DoCatz's Builds page breaks), Compose differences, different events and inspect details. DoCatz would need a second code path. Medium work, permanent second-class behaviour |
| **C. Hybrid** | our daemon for container lifecycle, dockerd started on demand for builds and the long tail | most of §1 while no build runs | Two image / container stores to keep in step, or one store two daemons write — the hard problem of A plus a seam. Not smaller than A in practice |
| **D. Keep dockerd, lighten the shim** | containerd's Rust shim (`containerd-shim-runc-v2-rs`, containerd/rust-extensions) or crun's lower overhead, set as the default runtime in `daemon.json` | the per-container part: 6.5 MB → about 1–2 MB each | Small and reversible: one binary in the guest and a `daemon.json` line; Docker's API and behaviour stay Docker's. Risk: the Rust shim is younger (exec / stats / OOM events must be checked against DoCatz's features list) |
| **E. Nothing more** | Lite as it is: sleep, wake, answers while asleep | — | none |

## 4. Recommendation (taken: A cancelled)

1. **No-go on A (and C) for now.** The saving is real but bounded (~140 MB idle, 6.5 MB per container) and Lite's
   idle state is already 10 MB. The cost is unbounded and lands on one person, in exactly the code where mistakes are
   container escapes. Lite's promise is "lighter, not less"; A breaks that promise for a long time.
2. **No-go on B.** It trades memory for a permanent list of things that differ, and DoCatz's own Builds page.
3. **Go on D as one experiment**, time-boxed: build the Rust shim for the guest (both arches), run
   `docs/DOCATZ-FEATURES.md`'s checks and the measurements of §1 with 10 and 20 containers, and keep it only if every
   check passes and it saves at least 4 MB per container. If it does, it ships as a capability (`shim-rs`) with
   dockerd's own shim one config line away.
4. ~~Revisit A later~~ — cancelled by the user: Lite is only worth building where it is lighter.

## 5. (Cancelled) what A would have looked like

- One static binary in the guest (`docatzd`), beside dockerd at first: its own socket and data directory under
  `/var/lib/docatz` (already kept on the data disk), announced as capability `engine-docatzd`; DoCatz offers it as a
  third choice (Standard / Lite / Lite 2) and Move carries images and volumes across, as between engines today.
- Reuse, never rewrite: `runc` or `crun` for the container, containerd's content store and snapshotter libraries or
  `containers/storage` for images, BuildKit as its own process started on demand, CNI-less bridge + nftables as
  libnetwork does it, the Docker API types from `moby/moby/api`.
- Order: read-only API (list, inspect, events) → lifecycle (create, start, stop, logs, exec, wait, attach) → networks
  and DNS → volumes → pull → Compose's suite green → builds → the rest.
- Tests before code: DoCatz's features list, `docker compose` upstream e2e, the docker CLI's integration tests, and a
  replay of real Compose projects (Laravel Sail, a Postgres + Redis + worker stack, DevCatz's services).
