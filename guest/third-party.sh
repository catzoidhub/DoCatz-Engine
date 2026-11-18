#!/bin/sh
# THIRD-PARTY.md for a guest: every Alpine package in the root file system with its licence, and where its source is.
# Usage: third-party.sh <packages.txt> <kernel version> <alpine branch> <guest version>
set -eu
cat <<MD
# Third-party software in the DoCatz Engine guest $4

The guest (the Linux VM DoCatz's Lite engine runs) is built from Alpine Linux $3 packages plus DoCatz Engine's own
\`docatz-agent\` and init scripts (GPL-3.0, this repository). Each package below keeps its own licence.

- **Linux kernel** $2 (Alpine's \`linux-virt\`), GPL-2.0-only: its corresponding source — the kernel.org tarball,
  Alpine's \`.config\` and patches — is attached to the same release as
  \`linux-<version>-docatz-source.tar.xz\`.
- **Docker Engine (moby), containerd, runc**: Apache-2.0; their NOTICE files are in the packages' sources.
- **docatz-agent** (GPL-3.0, this repository) is built with Go's standard library and \`golang.org/x/sys\`, both
  BSD-3-Clause (Copyright The Go Authors).
- **Every other package**: its source is Alpine's: the build recipe at
  https://gitlab.alpinelinux.org/alpine/aports (branch $3-stable) and the upstream files at
  https://distfiles.alpinelinux.org/distfiles/v$3/.

| Package | Version | Licence |
| --- | --- | --- |
MD
# apk list: name-version-rRel arch {origin} (licence) [installed]
sed -n 's/^\([^ ]*\) [^ ]* {[^}]*} (\(.*\)) \[installed\]$/\1|\2/p' "$1" | while IFS='|' read -r nv lic; do
	name=$(echo "$nv" | sed 's/-[0-9][^-]*-r[0-9]*$//')
	ver=${nv#"$name-"}
	echo "| $name | $ver | $lic |"
done
