#!/bin/bash
# Measures Docker engines on this Mac, the same way for each (DoCatz TODO #106, "Measure first"):
#   cold start   engine stopped → `docker info` answers (seconds)
#   idle         memory of the engine's processes after 60 s with no container
#   10 running   memory with 10 nginx:alpine containers up for 30 s
# Memory is phys_footprint (what Activity Monitor shows as Memory) summed over the engine's VM process and helpers.
#
#   bench/measure.sh [engine…]       engines: lite standard orbstack colima docker-desktop kiri (default: those installed)
#
# Results go to out/bench/<date>.md. They are for internal use only: DoCatz's promotion shows its own numbers and never
# a comparison with a named product (DoCatz TODO #106).
#
# It STOPS and STARTS the engines it measures: containers running on them stop. Run it when nothing else needs them.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="$ROOT/out/bench"
mkdir -p "$OUT"
REPORT="$OUT/$(date +%Y-%m-%d-%H%M).md"
IDLE_WAIT="${IDLE_WAIT:-60}"
TEN_WAIT="${TEN_WAIT:-30}"
IMAGE="${IMAGE:-nginx:alpine}"

say() { printf '%s\n' "$*" >&2; }

vm_pids() { pgrep -f 'com.apple.Virtualization.VirtualMachine' | sort; }

# Sum of phys_footprint (MB) over the given PIDs.
footprint_mb() {
	local total=0 p kb
	for p in "$@"; do
		kb=$(footprint -p "$p" 2>/dev/null | awk '/phys_footprint:/ { v=$2; u=$3; if (u=="GB") v*=1024*1024; else if (u=="MB") v*=1024; print int(v); exit }')
		total=$((total + ${kb:-0}))
	done
	echo $((total / 1024))
}

wait_docker() { # host timeout
	local start=$SECONDS
	until docker -H "$1" info >/dev/null 2>&1; do
		((SECONDS - start > $2)) && return 1
		sleep 0.2
	done
}

now() { python3 -c 'import time; print(time.time())'; }

# ---------------------------------------------------------------- engines: start, stop, host, helper processes

LITE_DIR="$OUT/lite-vm"
LITE_SOCK="${TMPDIR%/}/docatz-bench/docker.sock"
LITE_CTL="${TMPDIR%/}/docatz-bench/vmm.sock"
lite_installed() { [ -x "$ROOT/out/docatz-vmm-$(uname -m)" ] && [ -f "$ROOT/out/guest-$(uname -m)/rootfs.img" ]; }
lite_host() { echo "unix://$LITE_SOCK"; }
lite_start() {
	local g="$ROOT/out/guest-$(uname -m)" b="$ROOT/out/docatz-vmm-$(uname -m)"
	mkdir -p "$LITE_DIR"
	[ -f "$LITE_DIR/data.img" ] || "$b" disk --path "$LITE_DIR/data.img" --size-gib 64 >/dev/null
	cat > "$LITE_DIR/config.json" <<JSON
{"kernel":"$g/vmlinux","initrd":"$g/initramfs.img","rootfs":"$g/rootfs.img","cmdline":"$(sed -n 's/.*"cmdline": "\([^"]*\)".*/\1/p' "$g/guest.json")",
 "data":"$LITE_DIR/data.img","cpus":4,"memoryMiB":4096,"rosetta":true,"shares":[{"path":"$HOME"}],
 "dockerSocket":"$LITE_SOCK","controlSocket":"$LITE_CTL","console":"$LITE_DIR/console.log","forwardPorts":true,"balloon":true}
JSON
	"$b" run --config "$LITE_DIR/config.json" > "$LITE_DIR/events.log" 2> "$LITE_DIR/vmm.log" &
}
lite_stop() {
	"$ROOT/out/docatz-vmm-$(uname -m)" ctl --socket "$LITE_CTL" stop >/dev/null 2>&1
	while pgrep -f "docatz-vmm-$(uname -m) run" >/dev/null; do sleep 0.2; done
}
lite_helpers() { pgrep -f "docatz-vmm-$(uname -m) run"; }

LIMACTL="$HOME/.docatz/lima/bin/limactl"
standard_installed() { [ -x "$LIMACTL" ] && [ -d "$HOME/.docatz/vm/docatz" ]; }
standard_host() { echo "unix://$HOME/.docatz/run/docker.sock"; }
standard_start() { LIMA_HOME="$HOME/.docatz/vm" "$LIMACTL" start --tty=false docatz >/dev/null 2>&1 & }
standard_stop() { LIMA_HOME="$HOME/.docatz/vm" "$LIMACTL" stop docatz >/dev/null 2>&1; }
standard_helpers() { pgrep -f "limactl hostagent.*docatz"; }

orbstack_installed() { command -v orb >/dev/null; }
orbstack_host() { echo "unix://$HOME/.orbstack/run/docker.sock"; }
orbstack_start() { orb start >/dev/null 2>&1 & }
orbstack_stop() { orb stop >/dev/null 2>&1; }
orbstack_helpers() { pgrep -f 'OrbStack Helper|orbstack/bin|vmgr'; }

colima_installed() { command -v colima >/dev/null; }
colima_host() { echo "unix://$HOME/.colima/default/docker.sock"; }
colima_start() { colima start >/dev/null 2>&1 & }
colima_stop() { colima stop >/dev/null 2>&1; }
colima_helpers() { pgrep -f 'limactl hostagent.*colima'; }

docker_desktop_installed() { [ -d /Applications/Docker.app ]; }
docker_desktop_host() { echo "unix://$HOME/.docker/run/docker.sock"; }
# Docker Desktop's own CLI: quitting the app with osascript ended its VM under the still-running backend, which then
# showed "the Docker Desktop VM stopped unexpectedly" (2026-11-18).
DDCLI=/Applications/Docker.app/Contents/Resources/bin/docker
docker_desktop_start() { "$DDCLI" desktop start >/dev/null 2>&1 & }
docker_desktop_stop() { "$DDCLI" desktop stop >/dev/null 2>&1; }
docker_desktop_helpers() { pgrep -f 'com.docker.backend|com.docker.virtualization|com.docker.vmnetd'; }

kiri_installed() { [ -d /Applications/Kiri.app ]; }
kiri_host() { echo "unix://$HOME/.kiri/run/docker.sock"; }
kiri_start() { open -g -a Kiri; }
kiri_stop() {
	osascript -e 'quit app "Kiri"' >/dev/null 2>&1
	# its VM is the daemon's: wait for it to go (it sleeps after a minute idle, or ends with the daemon)
	local v; for v in $(seq 1 90); do [ -z "$(kiri_vm)" ] && break; sleep 1; done
	local i
	for i in $(seq 1 50); do pgrep -f 'Kiri.app/Contents/MacOS/kiri' >/dev/null || break; sleep 0.2; done
	pgrep -f 'Kiri.app/Contents/MacOS/kiri' >/dev/null && say "kiri: its daemon stays after Quit (a launch agent): the start below is not a cold one"
}
kiri_helpers() { pgrep -f 'Kiri.app/Contents/MacOS/kiri'; }
# Kiri's VM: a Virtualization process started after the daemon (none while it sleeps).
kiri_vm() { local d; d=$(pgrep -f 'kiri daemon' | head -1); [ -n "$d" ] || return; for p in $(vm_pids); do [ "$(ps -p $p -o etimes= | tr -d ' ')" -lt "$(ps -p $d -o etimes= | tr -d ' ')" ] && echo $p; done; }

# ---------------------------------------------------------------- one engine

measure() {
	local e="$1" fn="${1//-/_}" host before vm t0 t1 cold idle ten pids
	"${fn}_installed" || { say "$e: not installed, skipped"; return; }
	host=$("${fn}_host")
	say "$e: stopping"
	"${fn}_stop"
	sleep 3
	before=$(vm_pids)
	say "$e: cold start"
	t0=$(now)
	"${fn}_start"
	if ! wait_docker "$host" 300; then
		say "$e: docker did not answer within 5 minutes"
		echo "| $e | did not start | | |" >> "$REPORT"
		return
	fi
	t1=$(now)
	cold=$(python3 -c "print(f'{$t1 - $t0:.1f}')")
	vm=$(comm -13 <(echo "$before") <(vm_pids) | tr '\n' ' ')
	pids="$vm $("${fn}_helpers" | tr '\n' ' ')"
	say "$e: up in ${cold}s (VM pids: ${vm:-none found}); idle ${IDLE_WAIT}s"
	sleep "$IDLE_WAIT"
	# A VM that starts later (Kiri's daemon answers `docker info` before its VM runs) counts from where it appears.
	vm=$(comm -13 <(echo "$before") <(vm_pids) | tr '\n' ' '); pids="$vm $("${fn}_helpers" | tr '\n' ' ')"
	idle=$(footprint_mb $pids)
	say "$e: idle ${idle} MB; starting 10 containers"
	docker -H "$host" pull -q "$IMAGE" >/dev/null
	for i in $(seq 1 10); do docker -H "$host" run -d --name "docatz-bench-$i" "$IMAGE" >/dev/null; done
	sleep "$TEN_WAIT"
	vm=$(comm -13 <(echo "$before") <(vm_pids) | tr '\n' ' '); pids="$vm $("${fn}_helpers" | tr '\n' ' ')"
	ten=$(footprint_mb $pids)
	say "$e: VM pids at 10 containers: ${vm:-none}"
	say "$e: 10 containers ${ten} MB"
	for i in $(seq 1 10); do docker -H "$host" rm -f "docatz-bench-$i" >/dev/null 2>&1; done
	echo "| $e | ${cold} s | ${idle} MB | ${ten} MB |" >> "$REPORT"
}

engines=("$@")
[ ${#engines[@]} -eq 0 ] && engines=(lite standard orbstack colima docker-desktop kiri)
{
	echo "# Engine measurements, $(date '+%Y-%m-%d %H:%M')"
	echo
	echo "Internal only (DoCatz TODO #106). $(sysctl -n machdep.cpu.brand_string), $(($(sysctl -n hw.memsize) / 1073741824)) GB, macOS $(sw_vers -productVersion)."
	echo "Idle after ${IDLE_WAIT} s; 10 × $IMAGE after ${TEN_WAIT} s. Memory = phys_footprint of the VM process + the engine's helpers."
	echo
	echo "| Engine | Cold start → docker info | Idle | 10 containers |"
	echo "| --- | --- | --- | --- |"
} > "$REPORT"
for e in "${engines[@]}"; do measure "$e"; done
say "report: $REPORT"
cat "$REPORT"
