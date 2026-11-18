#!/bin/sh
# Packs what vmm/build.sh and guest/build.sh left in out/ into the release assets (docs/CONTRACT.md §2):
#   out/release/docatz-vmm-<v>-darwin-<arch>.tar.gz, docatz-guest-<v>-<arch>.tar.gz, manifest.json, SHA256SUMS
# The kernel source tarball (guest/kernel-source.sh) is added when it is in out/release already.
set -eu
cd "$(dirname "$0")/.."
V="$(cat VERSION)"
R=out/release
mkdir -p "$R"
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
size() { wc -c < "$1" | tr -d ' '; }
entries=""
add() { # key file
	entries="$entries${entries:+,}
    \"$1\": { \"name\": \"$(basename "$2")\", \"sha256\": \"$(sha "$2")\", \"size\": $(size "$2") }"
}
for arch in arm64 x86_64; do
	if [ -f "out/docatz-vmm-$arch" ]; then
		d="$(mktemp -d)"
		cp "out/docatz-vmm-$arch" "$d/docatz-vmm"
		COPYFILE_DISABLE=1 tar -C "$d" -czf "$R/docatz-vmm-$V-darwin-$arch.tar.gz" docatz-vmm
		rm -rf "$d"
		add "vmm-darwin-$arch" "$R/docatz-vmm-$V-darwin-$arch.tar.gz"
	fi
	g="out/guest-$arch"
	if [ -f "$g/rootfs.img" ]; then
		# -S: rootfs.img stays sparse inside the archive (bsdtar and GNU tar both read that back).
		COPYFILE_DISABLE=1 tar -C "$g" -S -czf "$R/docatz-guest-$V-$arch.tar.gz" vmlinux initramfs.img rootfs.img guest.json THIRD-PARTY.md
		add "guest-$arch" "$R/docatz-guest-$V-$arch.tar.gz"
	fi
done
versions="{}"
for arch in arm64 x86_64; do
	[ -f "out/guest-$arch/guest.json" ] && versions="$(sed -n '/"versions"/,/}/p' "out/guest-$arch/guest.json" | sed '1s/.*"versions": //' | tr -d '\n' | sed 's/ *}.*$/ }/')" && break
done
cat > "$R/manifest.json" <<JSON
{
  "version": "$V",
  "protocol": 1,
  "minMacos": "13.0",
  "assets": {$entries
  },
  "versions": $versions
}
JSON
(cd "$R" && shasum -a 256 $(ls | grep -v '^SHA256SUMS$') > SHA256SUMS)
ls -la "$R"
