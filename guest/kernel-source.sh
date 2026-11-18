#!/bin/sh
# The guest kernel's corresponding source (GPL-2.0), for the release: the kernel.org tarball of the exact version,
# plus Alpine's build recipe for it (APKBUILD, config-virt.<arch>, patches) from aports.
#   guest/kernel-source.sh <kernel release, e.g. 6.12.117-0-virt> <alpine branch, e.g. 3.22> <out dir>
set -eu
KREL="$1"
BRANCH="$2"
OUT="$3"
KVER="${KREL%%-*}"             # 6.12.117
MAJOR="${KVER%%.*}"            # 6
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
D="$W/linux-$KVER-docatz-source"
mkdir -p "$D/alpine" "$OUT"
curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v$MAJOR.x/linux-$KVER.tar.xz" -o "$D/linux-$KVER.tar.xz"
API="https://gitlab.alpinelinux.org/api/v4/projects/alpine%2Faports/repository"
REF="$BRANCH-stable"
curl -fsSL "$API/tree?path=main/linux-lts&ref=$REF&per_page=100" \
	| tr ',' '\n' | sed -n 's/.*"path":"\(main\/linux-lts\/[^"]*\)".*/\1/p' | while read -r f; do
	curl -fsSL "https://gitlab.alpinelinux.org/alpine/aports/-/raw/$REF/$f" -o "$D/alpine/$(basename "$f")"
done
grep -q "^pkgver=$KVER\$" "$D/alpine/APKBUILD" || echo "warning: aports $REF has moved past $KVER (APKBUILD: $(grep '^pkgver=' "$D/alpine/APKBUILD"))" >&2
cat > "$D/README.md" <<MD
# Corresponding source of the DoCatz Engine guest kernel

- \`linux-$KVER.tar.xz\`: the Linux kernel $KVER from kernel.org, unchanged.
- \`alpine/\`: Alpine Linux's recipe that builds it as \`linux-virt\` ($KREL): \`APKBUILD\`, \`config-virt.aarch64\`,
  \`config-virt.x86_64\` and Alpine's patches, from aports \`$REF\` (main/linux-lts).
- DoCatz Engine applies no patches of its own and uses Alpine's binary package unchanged.

The kernel is licensed GPL-2.0-only; see COPYING in the tarball.
MD
tar -C "$W" -cJf "$OUT/linux-$KVER-docatz-source.tar.xz" "linux-$KVER-docatz-source"
echo "$OUT/linux-$KVER-docatz-source.tar.xz"
