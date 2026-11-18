#!/bin/sh
# Notarizes the docatz-vmm binaries of a published release with Apple, on this Mac, through a notarytool keychain
# profile (the Catzoid family's `mrcatz-notary`; NOTARY_PROFILE overrides). Notarization does not change the binary —
# Apple keeps the ticket and Gatekeeper looks it up online — so the release assets, SHA256SUMS and manifest.json stay
# as they are, and DoCatz's pins too. Nothing is uploaded to GitHub.
#   scripts/notarize.sh 0.1.3
set -eu
V="${1:?version, e.g. 0.1.3}"
PROFILE="${NOTARY_PROFILE:-mrcatz-notary}"
REPO="${REPO:-catzoidhub/DoCatz-Engine}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
cd "$W"
gh release download "v$V" --repo "$REPO" -p manifest.json -p "docatz-vmm-$V-darwin-*.tar.gz"
for arch in arm64 x86_64; do
	a="docatz-vmm-$V-darwin-$arch.tar.gz"
	want=$(python3 -c "import json,sys; print(json.load(open('manifest.json'))['assets']['vmm-darwin-$arch']['sha256'])")
	have=$(shasum -a 256 "$a" | cut -d' ' -f1)
	[ "$want" = "$have" ] || { echo "$a does not match manifest.json" >&2; exit 1; }
	mkdir "$arch" && tar -C "$arch" -xzf "$a"
	codesign -dv --verbose=2 "$arch/docatz-vmm" 2>&1 | grep -q "^Authority=Developer ID Application" || { echo "$a is not signed with Developer ID" >&2; exit 1; }
	ditto -c -k --keepParent "$arch/docatz-vmm" "$arch.zip"
	echo "submitting $a to Apple…"
	xcrun notarytool submit "$arch.zip" --keychain-profile "$PROFILE" --wait --timeout 30m --output-format json > "$arch.json"
	status=$(python3 -c "import json; print(json.load(open('$arch.json')).get('status',''))")
	id=$(python3 -c "import json; print(json.load(open('$arch.json')).get('id',''))")
	if [ "$status" != "Accepted" ]; then
		echo "$a: notarization $status ($id)" >&2
		xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
		exit 1
	fi
	echo "$a: Accepted ($id)"
done
# Accepted is the proof: Gatekeeper looks the ticket up online the first time a downloaded (quarantined) copy runs —
# a bare binary cannot be stapled, and `spctl -t exec` only judges apps ("does not seem to be an app"). Checked once
# by hand (0.1.3, 2026-11-18): a quarantined notarized copy runs; an ad-hoc one is blocked with a dialog.
echo "notarized: docatz-vmm $V, arm64 and x86_64"
