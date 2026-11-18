# DoCatz Engine contract (protocol 1)

What DoCatz's Lite backend (`DoCatz/src/main/engine/`) can rely on. Anything not written here may change between
releases. Changes that break it raise `protocol` (below); DoCatz refuses a `docatz-vmm` / guest whose protocol it does
not know.

Status: **v0.1.5 (2026-11-19)** — 0.1.0 plus one docatz-vmm per VM (`vmm.lock`, exit 3, 0.1.1), a shared `/` in the guest (`shared-mounts`, 0.1.2) docatz-vmm signed with Developer ID (0.1.3) and containerd's Rust shim as the default runtime (`shim-rs`, 0.1.4) and `host.docker.internal` reaching the Mac's loopback (`host-loopback`, `host-dns`, 0.1.5); protocol unchanged. Tested on Apple silicon (macOS 26): Docker ready ~1 s after `run`, TCP / UDP /
loopback ports, shares, Rosetta, `fsevents`, `trim`, `sleep` / `wake`, `stop`, crash restart. Not yet tried on an Intel
Mac or on macOS 13–15. macOS only: Windows Lite stays on WSL2 and Linux Lite waits for the daemon of our own (DoCatz
TODO #106, "Lite 2"); neither uses `docatz-vmm`.

## 1. The pieces

| Piece | What | Where it runs |
| --- | --- | --- |
| `docatz-vmm` | the VM helper: one Swift executable on Apple's Virtualization.framework | the Mac, started by DoCatz's engine helper (#107), one process per running VM |
| guest kernel | Alpine's `linux-virt`, uncompressed (`vmlinux`) | in the VM |
| `initramfs.img` | busybox + the modules needed to reach the root disk; mounts it and switches to it | in the VM, first second of boot |
| `rootfs.img` | Alpine minimal + dockerd / containerd / runc + `docatz-agent`, ext4, **read-only** | the VM's `vda` |
| data disk | `data.img`, sparse raw, ext4, made on first boot: `/var/lib/docker`, `/var/lib/containerd`, and `/var/lib/docatz` (kept for what is not Docker's: later machines / clusters). Everything else in the guest is a tmpfs layer that is new at each boot | the VM's `vdb` |
| `docatz-agent` | the guest's PID 1 after the switch: starts dockerd, forwards the Docker socket and ports over vsock, answers the control stream | in the VM |

Minimum macOS: **13.0** (Ventura) — the same as DoCatz (`electron-builder.yml`). Rosetta needs Apple silicon and 13.0;
saving / restoring the VM's state (`save`, `restoreFrom`) needs **14.0** and Apple silicon and is refused otherwise
(and is not the way to save memory: a restored VM has all of its memory resident — use `sleep`). Intel Macs run the x86_64
build without Rosetta.

## 2. Release files

A release is tagged `v<version>` on `catzoidhub/DoCatz-Engine` and holds:

| Asset | Contents |
| --- | --- |
| `docatz-vmm-<version>-darwin-arm64.tar.gz` | `docatz-vmm` (arm64), signed with Developer ID (hardened runtime, timestamp) and the `com.apple.security.virtualization` entitlement |
| `docatz-vmm-<version>-darwin-x86_64.tar.gz` | the same for Intel |
| `docatz-guest-<version>-arm64.tar.gz` | `vmlinux`, `initramfs.img`, `rootfs.img`, `guest.json`, `THIRD-PARTY.md` |
| `docatz-guest-<version>-x86_64.tar.gz` | the same for x86_64 (Intel Macs) |
| `linux-<kernel version>-docatz-source.tar.xz` | the guest kernel's corresponding source (GPL-2.0): Alpine's source tarball, its `.config` and our patches (none yet) |
| `manifest.json` | the list below, so DoCatz can pin one file instead of eight |
| `SHA256SUMS` | `sha256sum` lines for every other asset |

URL of each: `https://github.com/catzoidhub/DoCatz-Engine/releases/download/v<version>/<asset>`.

`manifest.json`:

```json
{
  "version": "0.1.0",
  "protocol": 1,
  "minMacos": "13.0",
  "assets": {
    "vmm-darwin-arm64":   { "name": "docatz-vmm-0.1.0-darwin-arm64.tar.gz", "sha256": "…", "size": 0 },
    "vmm-darwin-x86_64":  { "name": "docatz-vmm-0.1.0-darwin-x86_64.tar.gz", "sha256": "…", "size": 0 },
    "guest-arm64":        { "name": "docatz-guest-0.1.0-arm64.tar.gz", "sha256": "…", "size": 0 },
    "guest-x86_64":       { "name": "docatz-guest-0.1.0-x86_64.tar.gz", "sha256": "…", "size": 0 }
  },
  "versions": { "kernel": "6.12.x", "alpine": "3.22", "docker": "28.x", "containerd": "2.x", "runc": "1.x" }
}
```

DoCatz pins the four archives by SHA-256 in `components.ts` like Standard's files (the manifest only helps write that
pin). `guest.json` inside the guest archive repeats `version`, `protocol` and `versions`, and adds `cmdline` (the
kernel command line the guest expects; DoCatz passes it unchanged).

`guest.json` also lists `capabilities` (`docker`, `ports-tcp`, `ports-udp`, `ports-loopback`, `fsevents`, `trim`,
`rosetta`, `restart-on-panic`, `data-dir`, `shared-mounts` — `/` is a shared mount from boot, so `-v …:rshared` works, `shim-rs` — containers run under
containerd's Rust shim by default (runtime `runc-rs`; `--runtime runc` picks dockerd's Go shim), `host-loopback` and
`host-dns` — §7 "The Mac from inside", …). New guest features are **added to this list** and never raise `protocol`:
DoCatz asks for a capability before using it and ignores the ones it does not know, so an older DoCatz accepts a newer
guest.

Archives are plain gzip'd tar (`tar -xzf`), so no zstd is needed on the Mac. `rootfs.img` is stored sparse.

## 3. Files on the Mac

DoCatz chooses the folders. The suggested layout, next to Standard's `~/.docatz/vm`:

```
~/.docatz/lite/bin/docatz-vmm        the helper (unpacked from its archive)
~/.docatz/lite/guest/<version>/      vmlinux, initramfs.img, rootfs.img, guest.json (never written to)
~/.docatz/lite/vm/data.img           the data disk (sparse; its blocks in use = what the engine uses on disk)
~/.docatz/lite/vm/vmm.sock           docatz-vmm's control socket (0600)
~/.docatz/lite/vm/console.log        the guest's console (kernel + agent log), truncated at each start
~/.docatz/lite/vm/state.vzstate      a saved state (save / restore, macOS 14+)
~/.docatz/lite/vm/vmm.lock           held by the running docatz-vmm (its pid inside)
~/.docatz/lite/vm/machine-id, mac    the VM's identity (made by docatz-vmm next to data.img; Reset deletes them with it)
~/.docatz/run/docker.sock            the Docker socket: the same path as Standard, so the `docatz` context does not change
```

## 4. Command line

```
docatz-vmm version
    prints {"version":"0.1.0","protocol":1,"arch":"arm64","macos":"15.5","rosetta":true,"saveRestore":true}

docatz-vmm disk --path <data.img> --size-gib <n>
    creates the data disk (sparse) or grows it to n GiB; never shrinks. The guest grows the file system at its next boot.
    Exit 0, or 1 with {"error": "..."} on stdout.

docatz-vmm run --config <config.json>
    starts the VM and runs until it stops. stdout: one JSON event per line (§6); stderr: the helper's own log.
    Exit 0 = the VM stopped cleanly, 1 = it failed (the last stdout line is {"event":"error","message":"..."}),
    2 = bad config, 3 = another docatz-vmm already runs this VM (`vmm.lock` next to the data disk holds its pid; the
    error line carries it as `running`): talk to that one through its control socket instead.

docatz-vmm ctl --socket <vmm.sock> <method> [json params]
    sends one control request (§5) and prints the answer — for people and tests.
```

`config.json` (every path absolute):

```json
{
  "kernel": "/Users/me/.docatz/lite/guest/0.1.0/vmlinux",
  "initrd": "/Users/me/.docatz/lite/guest/0.1.0/initramfs.img",
  "rootfs": "/Users/me/.docatz/lite/guest/0.1.0/rootfs.img",
  "cmdline": "<guest.json's cmdline>",
  "data": "/Users/me/.docatz/lite/vm/data.img",
  "cpus": 4,
  "memoryMiB": 4096,
  "rosetta": true,
  "shares": [{ "path": "/Users/me", "readOnly": false }],
  "dockerSocket": "/Users/me/.docatz/run/docker.sock",
  "controlSocket": "/Users/me/.docatz/lite/vm/vmm.sock",
  "console": "/Users/me/.docatz/lite/vm/console.log",
  "forwardPorts": true,
  "balloon": true,
  "restoreFrom": null
}
```

- `shares`: each folder is shared over virtiofs and mounted in the guest **at the same path**, so a bind mount
  `-v /Users/me/site:/app` works as on Standard. `/Users/<you>` is the usual one; more may follow (`/Volumes/…`,
  `/private/tmp`).
- `rosetta` is ignored (false) on Intel and when Rosetta is not installed (`version` says which).
- `restoreFrom`: a saved state to resume from (macOS 14+); when it fails the VM boots normally and an
  `{"event":"restore-failed"}` line says why.

## 5. The control socket

`controlSocket` is a Unix socket (0600, only the user). One JSON object per line each way; requests carry an `id`,
answers echo it; events have no `id`. Never TCP.

```
→ {"id":1,"method":"status"}
← {"id":1,"result":{"state":"running","version":"0.1.0","pid":4242,"guest":{"agent":"0.1.0","docker":true,"bootMs":1830},
                    "memory":{"configuredMiB":4096,"targetMiB":4096},"ports":[{"proto":"tcp","port":8080}],
                    "connections":{"docker":1,"ports":0,"quietSec":42}}}
← {"id":2,"error":"unknown method"}
```

| Method | Params | Does |
| --- | --- | --- |
| `status` | — | as above; `state` is `starting`, `running`, `stopping`, `sleeping`, `stopped` or `error` |
| `stop` | `{"timeoutSec":20}` | asks the guest to stop (dockerd stops its containers, file systems are synced), then ends the VM after the timeout; the process exits when it is stopped |
| `sleep` | `{"timeoutSec":20,"maxConnections":1}` | idle sleep: the guest stops cleanly (as `stop`) and its memory goes back to the Mac, but the process stays (about 12 MB) with the Docker socket; `state` becomes `sleeping`. The **first connection to the Docker socket** that needs dockerd (or `wake`) boots it again, about 1.1 s (§7: some read-only calls are answered without waking); containers with a restart policy come back. Refused unless `running`, and — with `maxConnections` — when more Docker connections than that are open (`"in use: …"`; checked atomically, so a `docker build` that has just connected is never cut off; DoCatz passes the number of connections it holds itself, e.g. 1 for its events stream). `status`' `connections` gives the open Docker / port connections and `quietSec`, the seconds since one last opened or closed. DoCatz decides when (nothing running, nobody using it) and must not touch the socket itself while it wants the VM asleep. Published ports are not listened on while asleep |
| `wake` | — | boots a sleeping guest; nothing otherwise |
| `kill` | — | ends the VM at once (last resort; the data disk may need its journal replayed) |
| `ports` | — | the forwarded ports |
| `fsevents` | `{"files":[{"path":"/Users/me/site/app.js","mtime":"1731900000.123456789"}]}` | raises inotify events in the guest for files changed on the Mac (virtiofs does not) by setting each file's modification time again to the Mac's value (seconds.nanoseconds, as Standard's `touch -c -m -d @<mtime>`), so nothing changes; up to 1000 files per call |
| `balloon` | `{"targetMiB":2048}` | asks the guest to give memory back down to that size (the balloon device); `0` = back to the configured size |
| `sync-time` | — | sets the guest clock from the Mac's (done by itself after the Mac wakes) |
| `trim` | — | `fstrim` in the guest: the data disk's freed blocks go back to the Mac now |
| `save` | `{"path":".../state.vzstate"}` | macOS 14+: pauses the VM and saves its state; the process then exits 0 |
| `subscribe` | — | events (§6) also come on this connection from now on |

## 6. Events

On `run`'s stdout and on subscribed connections:

```
{"event":"state","state":"starting"}
{"event":"state","state":"running","bootMs":1830}      the agent answered and dockerd is ready on the socket
{"event":"ports","ports":[{"proto":"tcp","port":8080}]}  the forwarded list changed
{"event":"state","state":"starting","restart":1,"reason":"the guest restarted"}
                                          the guest crashed (a kernel panic reboots it) and is booting again;
                                          at most 3 times a minute, then `error` and exit 1
{"event":"state","state":"stopping","sleep":true}    `sleep` was asked
{"event":"state","state":"sleeping"}
{"event":"state","state":"starting","wake":true}     a Docker connection or `wake`
{"event":"state","state":"stopping"}
{"event":"state","state":"stopped"}
{"event":"error","message":"..."}
```

## 7. What is forwarded

- **Docker socket**: `dockerSocket` on the Mac (made by the helper, 0600; a stale file is replaced). Every
  connection goes over vsock to the agent, which joins it to `/var/run/docker.sock` in the guest. The socket exists
  from `starting` on; connections made before dockerd is ready wait for it (up to 60 s).
- **While asleep** (`sleep`), docatz-vmm answers these on the Docker socket itself with dockerd's own answers taken
  just before the guest stopped, so pollers and a terminal do not boot the VM: `GET`/`HEAD /_ping`, `GET /version`,
  `GET /info`, and `GET /containers/json` (plain or `all=1`) — the list only when every container running at sleep has
  an `always` / `unless-stopped` restart policy (they are back on wake, so the list stays true). With any other query
  (filters…) or any other request, the guest wakes and the request goes through unchanged. `status` →
  `asleep: {answers, answered}`.
- **Ports**: every TCP port the guest listens on for all addresses (`0.0.0.0` / `::`, which is what `docker run -p`
  makes) **or on the VM's loopback** (`127.0.0.1` / `::1`, as Lima forwards them: DoCatz's `docatz-router` runs on the
  VM's host network on 127.0.0.1) is listened on at `127.0.0.1` and `::1` on the Mac, and each connection goes over
  vsock to the agent, which connects to it in the guest. A port that is taken on the Mac is skipped and reported in the
  `ports` event with `"error":"in use"`.
- **UDP ports** (`{"proto":"udp",…}` in `ports`): sockets bound in the guest to every address or loopback, below
  the ephemeral range (what `-p 53:53/udp` makes), are bound on `127.0.0.1` and `::1` on the Mac; each client address
  gets its own stream to the guest, kept for 60 s after its last datagram. Datagrams up to 65,535 bytes.
- **A guest that crashes** reboots inside the same VM (`oops=panic panic=-1` in guest.json's cmdline): the open Docker
  and port connections end at once (no client waits on a dead guest), `state` goes `starting` with `restart` and back
  to `running` about a second later. More than 3 restarts in a minute ends `run` with an error.
- **Container IPs**: the guest has a NAT network (Virtualization.framework's), so the Mac reaches the guest at its
  address; DoCatz's router (`docatz-router` container) works as on Standard.
- **Mounts**: `shares` over virtiofs at the same paths; file events through `fsevents` above.
- **DNS / internet**: the NAT's DNS for the VM itself.
- **The Mac from inside** (capability `host-loopback`): `198.19.200.2` in the guest is the **Mac's loopback**. Every TCP
  connection to it, from any container or network, reaches the Mac's `127.0.0.1:<same port>` (else `[::1]`): the guest
  DNATs it to `docatz-agent`, which calls `docatz-vmm` on the host's vsock port **2378** with `tcp <port>\n`; `docatz-vmm`
  answers one byte (`1` joined, `0` nothing listens — the container then gets a reset, as from a closed port) and joins
  the streams. So a container reaches a database or dev server that listens only on the Mac's 127.0.0.1 (DevCatz's).
  TCP only; the Mac's other addresses (LAN, the NAT's `192.168.64.1`) stay reachable through the NAT as before.
- **Names** (capability `host-dns`): dockerd's DNS is `198.19.200.3` (daemon.json `dns`), served by the agent: it
  answers `host.docker.internal`, `gateway.docker.internal`, `host.lima.internal`, `host.docatz.internal`,
  `docker.for.mac.host.internal` and `docker.for.mac.localhost` with `198.19.200.2` (A; other types empty) and passes
  everything else to the VM's nameservers. The default bridge uses it directly, a user-defined network through Docker's
  embedded DNS, so **every container resolves the name with no `extra_hosts`**. dockerd's `host-gateway-ip` is
  `198.19.200.2` too, so `extra_hosts: host.docker.internal:host-gateway` gives the same address (dockerd 28.3 writes
  it as `::ffff:198.19.200.2` in the container's `/etc/hosts`, whichever daemon.json key sets it; it connects the same). The
  VM's `/etc/hosts` has the same names.

## 8. Versions and upgrades

- `protocol` changes only when this file's promises break; new methods / fields / events do not raise it.
- A guest and a `docatz-vmm` of the same release always go together. DoCatz upgrades both while the VM is stopped;
  `data.img` survives every upgrade (a guest that needs a newer layout migrates it at boot).
- A release outside DoCatz's own (a kernel / runc fix of the container-escape class) keeps the protocol, so DoCatz
  can take it by changing its pins only.
