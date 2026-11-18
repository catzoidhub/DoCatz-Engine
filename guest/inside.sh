#!/bin/sh
# Runs inside an Alpine container of the guest's arch (build.sh starts it) and writes out/guest-<arch>/:
#   vmlinux  initramfs.img  rootfs.img  guest.json  THIRD-PARTY.md  packages.txt
set -eu
ARCH="$1"          # arm64 | x86_64
VERSION="$2"
SRC=/src
OUT="$SRC/out/guest-$ARCH"
W=/work
rm -rf "$OUT" "$W"
mkdir -p "$OUT" "$W"

apk add --no-cache -q e2fsprogs kmod cpio gzip xz zstd findutils busybox-static file

apkroot() { # <root> <scripts|no-scripts> <packages…>
	r="$1"
	scripts="$2"
	shift 2
	mkdir -p "$r/etc/apk"
	cp -r /etc/apk/keys "$r/etc/apk/"
	cp /etc/apk/repositories "$r/etc/apk/repositories"
	apk add -q --root "$r" --initdb --no-cache $([ "$scripts" = no-scripts ] && echo --no-scripts) "$@"
}

# ---------------------------------------------------------------- kernel
apkroot "$W/kernel" no-scripts linux-virt
KVER=$(ls "$W/kernel/lib/modules" | head -1)
VMLINUZ="$W/kernel/boot/vmlinuz-virt"
case "$(file -b "$VMLINUZ")" in
	gzip*) gunzip -c "$VMLINUZ" > "$OUT/vmlinux" ;;
	*) cp "$VMLINUZ" "$OUT/vmlinux" ;;
esac
# EFI zboot images (a PE whose payload is compressed) are unpacked: Virtualization.framework boots a plain Image.
if [ "$(dd if="$OUT/vmlinux" bs=1 skip=4 count=4 2>/dev/null)" = "zimg" ]; then
	off=$(od -An -tu4 -j8 -N4 "$OUT/vmlinux" | tr -d ' ')
	size=$(od -An -tu4 -j12 -N4 "$OUT/vmlinux" | tr -d ' ')
	comp=$(dd if="$OUT/vmlinux" bs=1 skip=24 count=8 2>/dev/null | tr -d '\0')
	dd if="$OUT/vmlinux" bs=1 skip="$off" count="$size" 2>/dev/null > "$W/payload"
	case "$comp" in
		gzip) gunzip -c "$W/payload" > "$OUT/vmlinux" ;;
		zstd*) zstd -dc "$W/payload" > "$OUT/vmlinux" ;;
		xzkern|xz) xz -dc "$W/payload" > "$OUT/vmlinux" ;;
		*) echo "unknown zboot compression: $comp" >&2; exit 1 ;;
	esac
fi
echo "kernel $KVER: $(file -b "$OUT/vmlinux" | cut -c1-80)"

# ---------------------------------------------------------------- initramfs: busybox + what reaches vda
I="$W/initramfs"
mkdir -p "$I/bin" "$I/dev" "$I/proc" "$I/sys" "$I/mod"
cp /bin/busybox.static "$I/bin/busybox"
cp "$SRC/guest/initramfs/init" "$I/init"
chmod 0755 "$I/init" "$I/bin/busybox"
: > "$I/modules.list"
modprobe -d "$W/kernel" -S "$KVER" -a --show-depends virtio_pci virtio_blk ext4 overlay virtio_rng 2>/dev/null \
	| awk '$1 == "insmod" { print $2 }' | awk '!seen[$0]++' | while read -r ko; do
	name=$(basename "$ko" | sed 's/\.ko.*$//')
	case "$ko" in
		*.gz) gunzip -c "$ko" > "$I/mod/$name.ko" ;;
		*.xz) xz -dc "$ko" > "$I/mod/$name.ko" ;;
		*.zst) zstd -dcq "$ko" > "$I/mod/$name.ko" ;;
		*) cp "$ko" "$I/mod/$name.ko" ;;
	esac
	echo "/mod/$name.ko" >> "$I/modules.list"
done
echo "initramfs modules: $(wc -l < "$I/modules.list")"
(cd "$I" && find . | sort | cpio -o -H newc --quiet | gzip -9) > "$OUT/initramfs.img"

# ---------------------------------------------------------------- root file system
R="$W/rootfs"
# Package scripts run (busybox links its applets, docker-engine adds its group): the container is the guest's arch.
apkroot "$R" scripts alpine-baselayout busybox busybox-binsh musl-utils ca-certificates-bundle \
	docker-engine containerd runc iptables ip6tables e2fsprogs e2fsprogs-extra blkid util-linux-misc jq kmod tzdata pigz
mkdir -p "$R/lib/modules"
cp -a "$W/kernel/lib/modules/$KVER" "$R/lib/modules/"
depmod -b "$R" "$KVER"
cp -a "$SRC/guest/rootfs/." "$R/"
cp "$SRC/out/agent-$( [ "$ARCH" = arm64 ] && echo arm64 || echo amd64 )" "$R/usr/bin/docatz-agent"
chmod 0755 "$R/usr/bin/docatz-agent" "$R/sbin/docatz-init"
printf 'docatz\n' > "$R/etc/hostname"
printf '127.0.0.1\tlocalhost docatz\n::1\tlocalhost docatz\n' > "$R/etc/hosts"
# What the image does not need at run time.
rm -rf "$R/var/cache/apk"/* "$R/usr/share/man" "$R/usr/share/doc"
apk --root "$R" list --installed 2>/dev/null | sort > "$OUT/packages.txt"
rm -rf "$R/etc/apk" "$R/lib/apk" "$R/usr/share/apk"
echo "$VERSION" > "$R/etc/docatz-guest"
# docker info's OperatingSystem: what the engine is, then what it is built on.
rm -f "$R/etc/os-release"
printf 'NAME="DoCatz Engine"\nID=docatz\nID_LIKE=alpine\nVERSION_ID=%s\nPRETTY_NAME="DoCatz Engine %s (Alpine %s)"\nHOME_URL="https://github.com/catzoidhub/DoCatz-Engine"\n' \
	"$VERSION" "$VERSION" "$(cut -d. -f1,2 /etc/alpine-release)" > "$R/etc/os-release"

used=$(du -sm "$R" | cut -f1)
size=$((used * 115 / 100 + 64))
mkfs.ext4 -q -F -L docatz-root -O ^has_journal -m 0 -b 4096 -d "$R" "$OUT/rootfs.img" "${size}M"
echo "rootfs: ${used} MB used, image ${size} MB"

# ---------------------------------------------------------------- versions, licences
ALPINE=$(cut -d. -f1,2 /etc/alpine-release)
v() { awk -v p="$1" 'index($1, p "-") == 1 { s = $1; sub("^" p "-", "", s); sub("-r[0-9]+$", "", s); print s; exit }' "$OUT/packages.txt"; }
cat > "$OUT/guest.json" <<JSON
{
  "version": "$VERSION",
  "protocol": 1,
  "arch": "$ARCH",
  "cmdline": "console=hvc0 loglevel=4 cgroup_no_v1=all init_on_alloc=0 oops=panic panic=-1",
  "capabilities": ["docker", "ports-tcp", "ports-udp", "ports-loopback", "fsevents", "trim", "rosetta", "restart-on-panic", "data-dir"],
  "versions": { "kernel": "$KVER", "alpine": "$ALPINE", "docker": "$(v docker-engine)", "containerd": "$(v containerd)", "runc": "$(v runc)" }
}
JSON
sh "$SRC/guest/third-party.sh" "$OUT/packages.txt" "$KVER" "$ALPINE" "$VERSION" > "$OUT/THIRD-PARTY.md"
ls -la "$OUT"
