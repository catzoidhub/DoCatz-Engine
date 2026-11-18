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
curl -fsSL --retry 4 --retry-delay 5 "https://cdn.kernel.org/pub/linux/kernel/v$MAJOR.x/linux-$KVER.tar.xz" -o "$D/linux-$KVER.tar.xz"
REF="$BRANCH-stable"
# Alpine's recipe from aports, through git (GitLab's web API answers CI runners with 418, its bot wall): GitHub's
# official mirror first, then Alpine's own.
for url in https://github.com/alpinelinux/aports.git https://gitlab.alpinelinux.org/alpine/aports.git; do
	rm -rf "$W/aports"
	if git clone -q --depth 1 --filter=blob:none --sparse --branch "$REF" "$url" "$W/aports" 2>/dev/null &&
		git -C "$W/aports" sparse-checkout set main/linux-lts 2>/dev/null &&
		[ -f "$W/aports/main/linux-lts/APKBUILD" ]; then
		cp "$W/aports/main/linux-lts/"* "$D/alpine/"
		git -C "$W/aports" rev-parse HEAD > "$D/alpine/APORTS_COMMIT"
		break
	fi
done
[ -f "$D/alpine/APKBUILD" ] || { echo "aports $REF could not be fetched" >&2; exit 1; }
grep -q "^pkgver=$KVER\$" "$D/alpine/APKBUILD" || echo "warning: aports $REF has moved past $KVER (APKBUILD: $(grep '^pkgver=' "$D/alpine/APKBUILD"))" >&2
cat > "$D/README.md" <<MD
# Corresponding source of the DoCatz Engine guest kernel

- \`linux-$KVER.tar.xz\`: the Linux kernel $KVER from kernel.org, unchanged.
- \`alpine/\`: Alpine Linux's recipe that builds it as \`linux-virt\` ($KREL): \`APKBUILD\`, \`virt.aarch64.config\`,
  \`virt.x86_64.config\` and Alpine's patches, from aports \`$REF\` (main/linux-lts, the commit in \`APORTS_COMMIT\`).
- DoCatz Engine applies no patches of its own and uses Alpine's binary package unchanged.

The kernel is licensed GPL-2.0-only; see COPYING in the tarball.
MD
tar -C "$W" -cJf "$OUT/linux-$KVER-docatz-source.tar.xz" "linux-$KVER-docatz-source"
echo "$OUT/linux-$KVER-docatz-source.tar.xz"
