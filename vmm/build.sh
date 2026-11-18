#!/bin/sh
# Builds docatz-vmm for this Mac's arch (or the one given) and signs it with the virtualization entitlement.
#   vmm/build.sh [arm64|x86_64] [identity]
# identity: a "Developer ID Application: …" name, or "-" (ad hoc, the default; enough for the entitlement).
set -eu
cd "$(dirname "$0")"
ARCH="${1:-$(uname -m)}"
IDENTITY="${2:--}"
VERSION="$(cat ../VERSION)"
sed -i '' "s/^let VERSION = \".*\"/let VERSION = \"$VERSION\"/" Sources/docatz-vmm/main.swift
swift build -c release --arch "$ARCH"
BIN=".build/$ARCH-apple-macosx/release/docatz-vmm"
OPTS="--force --entitlements vmm.entitlements"
[ "$IDENTITY" = "-" ] || OPTS="$OPTS --options runtime --timestamp"
codesign $OPTS --sign "$IDENTITY" "$BIN"
mkdir -p ../out
cp "$BIN" "../out/docatz-vmm-$ARCH"
echo "../out/docatz-vmm-$ARCH ($VERSION, signed by $IDENTITY)"
