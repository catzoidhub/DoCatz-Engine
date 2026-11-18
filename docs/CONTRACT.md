# DoCatz Engine contract (protocol 1)

What DoCatz's Lite backend (`DoCatz/src/main/engine/`) can rely on. Anything not written here may change between
releases. Changes that break it raise `protocol` (below); DoCatz refuses a `docatz-vmm` / guest whose protocol it does
not know.

Status: **draft 1 (2026-11-18)**, built and booted on Apple silicon (macOS 26): Docker ready ~2.5 s after `run`,
ports, shares, Rosetta, `fsevents`, `trim`, `stop` tested; not released yet (no v0.1.0 tag) — macOS only. Windows Lite stays on WSL2 and Linux Lite waits for the daemon of our
own (DoCatz TODO #106, "Lite 2"); neither uses `docatz-vmm`.

## 1. The pieces

| Piece | What | Where it runs |
| --- | --- | --- |
| `docatz-vmm` | the VM helper: one Swift executable on Apple's Virtualization.framework | the Mac, started by DoCatz's engine helper (#107), one process per running VM |
| guest kernel | Alpine's `linux-virt`, uncompressed (`vmlinux`) | in the VM |
| `initramfs.img` | busybox + the modules needed to reach the root disk; mounts it and switches to it | in the VM, first second of boot |
| `rootfs.img` | Alpine minimal + dockerd / containerd / runc + `docatz-agent`, ext4, **read-only** | the VM's `vda` |
| data disk | `data.img`, sparse raw, ext4, made on first boot: `/var/lib/docker`, the writable layer over `/etc` and `/var` | the VM's `vdb` |
| `docatz-agent` | the guest's PID 1 after the switch: starts dockerd, forwards the Docker socket and ports over vsock, answers the control stream | in the VM |

Minimum macOS: **13.0** (Ventura) — the same as DoCatz (`electron-builder.yml`). Rosetta needs Apple silicon and 13.0;
saving / restoring the VM's state (`save`, `restore`) needs **14.0** and is refused below it. Intel Macs run the x86_64
build without Rosetta.

## 2. Release files

A release is tagged `v<version>` on `catzoidhub/DoCatz-Engine` and holds:

| Asset | Contents |
| --- | --- |
| `docatz-vmm-<version>-darwin-arm64.tar.gz` | `docatz-vmm` (arm64), signed with the `com.apple.security.virtualization` entitlement |
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
    2 = bad config.

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
                    "memory":{"configuredMiB":4096,"targetMiB":4096},"ports":[{"proto":"tcp","port":8080}]}}
← {"id":2,"error":"unknown method"}
```

| Method | Params | Does |
| --- | --- | --- |
| `status` | — | as above; `state` is `starting`, `running`, `stopping`, `stopped` or `error` |
| `stop` | `{"timeoutSec":20}` | asks the guest to stop (dockerd stops its containers, file systems are synced), then ends the VM after the timeout; the process exits when it is stopped |
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
{"event":"state","state":"stopping"}
{"event":"state","state":"stopped"}
{"event":"error","message":"..."}
```

## 7. What is forwarded

- **Docker socket**: `dockerSocket` on the Mac (made by the helper, 0600; a stale file is replaced). Every
  connection goes over vsock to the agent, which joins it to `/var/run/docker.sock` in the guest. The socket exists
  from `starting` on; connections made before dockerd is ready wait for it (up to 60 s).
- **Ports**: every TCP port the guest listens on for all addresses (`0.0.0.0` / `::`, which is what `docker run -p`
  makes) **or on the VM's loopback** (`127.0.0.1` / `::1`, as Lima forwards them: DoCatz's `docatz-router` runs on the
  VM's host network on 127.0.0.1) is listened on at `127.0.0.1` and `::1` on the Mac, and each connection goes over
  vsock to the agent, which connects to it in the guest. A port that is taken on the Mac is skipped and reported in the
  `ports` event with `"error":"in use"`. UDP: not yet.
- **A guest that crashes** reboots inside the same VM (`oops=panic panic=-1` in guest.json's cmdline): the open Docker
  and port connections end at once (no client waits on a dead guest), `state` goes `starting` with `restart` and back
  to `running` about a second later. More than 3 restarts in a minute ends `run` with an error.
- **Container IPs**: the guest has a NAT network (Virtualization.framework's), so the Mac reaches the guest at its
  address; DoCatz's router (`docatz-router` container) works as on Standard.
- **Mounts**: `shares` over virtiofs at the same paths; file events through `fsevents` above.
- **DNS / internet**: the NAT's DNS. In the VM `host.docker.internal` is the NAT gateway (the Mac), and dockerd's
  `host-gateway` is that address too (as Standard sets it), so `extra_hosts: host.docker.internal:host-gateway`
  reaches the Mac from a container — as on Standard, a container without that line does not resolve the name.

## 8. Versions and upgrades

- `protocol` changes only when this file's promises break; new methods / fields / events do not raise it.
- A guest and a `docatz-vmm` of the same release always go together. DoCatz upgrades both while the VM is stopped;
  `data.img` survives every upgrade (a guest that needs a newer layout migrates it at boot).
- A release outside DoCatz's own (a kernel / runc fix of the container-escape class) keeps the protocol, so DoCatz
  can take it by changing its pins only.
