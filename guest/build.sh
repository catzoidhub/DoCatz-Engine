#!/bin/sh
# Builds the guest for one arch with Docker (any engine: DoCatz, Docker Desktop, the CI's).
#   guest/build.sh arm64|x86_64 [version]
set -eu
cd "$(dirname "$0")/.."
ARCH="${1:?arm64 or x86_64}"
VERSION="${2:-$(cat VERSION)}"
ALPINE_IMAGE="${ALPINE_IMAGE:-alpine:3.22}"
case "$ARCH" in
	arm64) PLATFORM=linux/arm64 GOARCH=arm64 ;;
	x86_64) PLATFORM=linux/amd64 GOARCH=amd64 ;;
	*) echo "arch is arm64 or x86_64" >&2; exit 2 ;;
esac
mkdir -p out
(cd agent && GOOS=linux GOARCH=$GOARCH CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X main.version=$VERSION" -o ../out/agent-$GOARCH .)
docker run --rm --platform "$PLATFORM" -v "$PWD:/src" "$ALPINE_IMAGE" sh /src/guest/inside.sh "$ARCH" "$VERSION"
