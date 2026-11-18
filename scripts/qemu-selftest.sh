#!/bin/sh
# Boots a guest under QEMU with `docatz.selftest`: the agent pulls busybox, runs one container on the default runtime,
# prints `docatz-selftest: PASS …` (or FAIL) and powers off. For a guest this machine cannot run with docatz-vmm — the
# x86_64 guest on an Apple silicon Mac (emulated, minutes) — and for CI (KVM, seconds). No vsock is needed.
#   scripts/qemu-selftest.sh <guest dir: vmlinux, initramfs.img, rootfs.img, guest.json> [x86_64|arm64] [timeout s]
set -eu
G="${1:?guest folder}"
ARCH="${2:-x86_64}"
LIMIT="${3:-900}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
CMD="$(sed -n 's/.*"cmdline": "\([^"]*\)".*/\1/p' "$G/guest.json")"
truncate -s 8G "$W/data.img"
case "$ARCH" in
	x86_64)
		QEMU=qemu-system-x86_64
		CON=ttyS0
		if [ -e /dev/kvm ] && [ -w /dev/kvm ]; then MACH="-machine q35,accel=kvm -cpu host"; else MACH="-machine q35 -cpu max"; fi ;;
	arm64)
		QEMU=qemu-system-aarch64
		CON=ttyAMA0
		if [ -e /dev/kvm ] && [ -w /dev/kvm ]; then MACH="-machine virt,accel=kvm -cpu host"; else MACH="-machine virt -cpu max"; fi ;;
	*) echo "arch is x86_64 or arm64" >&2; exit 2 ;;
esac
echo "booting the $ARCH guest under $QEMU ($MACH), at most $LIMIT s…"
# shellcheck disable=SC2086
$QEMU $MACH -m 2048 -smp 2 -nographic -no-reboot \
	-kernel "$G/vmlinux" -initrd "$G/initramfs.img" -append "$CMD console=$CON docatz.selftest" \
	-drive "file=$G/rootfs.img,if=virtio,format=raw,readonly=on" \
	-drive "file=$W/data.img,if=virtio,format=raw" \
	-netdev user,id=n -device virtio-net-pci,netdev=n \
	-device virtio-rng-pci \
	> "$W/console.log" 2>&1 &
PID=$!
i=0
while kill -0 "$PID" 2>/dev/null && [ "$i" -lt "$LIMIT" ]; do
	grep -q "docatz-selftest:" "$W/console.log" 2>/dev/null && break
	sleep 1
	i=$((i + 1))
done
sleep 3
kill "$PID" 2>/dev/null || true
grep -E "docatz-init|docatz-agent|docatz-selftest|Kernel panic|Internal error" "$W/console.log" | sed 's/\x1b\[[0-9;]*m//g' | tail -15
grep -q "docatz-selftest: PASS" "$W/console.log"
