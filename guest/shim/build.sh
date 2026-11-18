#!/bin/sh
# Builds containerd's Rust runc shim (containerd/rust-extensions, Apache-2.0) for the guest: a static musl binary
# containerd-shim-runc-v2-rs, so dockerd can run containers with runtime "io.containerd.runc.v2-rs" (LITE2.md §3 D).
#   guest/shim/build.sh arm64|x86_64 [tag]
# guest/shim/*.patch are applied first (oom-cgroup2.patch: OOM kills reported on cgroup v2, as dockerd's Go shim does).
set -eu
cd "$(dirname "$0")/../.."
ARCH="${1:?arm64 or x86_64}"
TAG="${2:-shim-v0.12.0}"
case "$ARCH" in arm64) PLATFORM=linux/arm64 ;; x86_64) PLATFORM=linux/amd64 ;; *) exit 2 ;; esac
mkdir -p out
# The official Rust image on Alpine (musl): Alpine 3.22's own rustc (1.87) is older than the crates need.
docker run --rm --platform "$PLATFORM" -v "$PWD/out:/out" -v "$PWD/guest/shim:/patches:ro" "${RUST_IMAGE:-rust:1-alpine3.22}" sh -euc "
  apk add -q --no-cache git protobuf-dev protoc musl-dev
  git clone -q --depth 1 --branch '$TAG' https://github.com/containerd/rust-extensions /src
  cd /src
  # Our patches (guest/shim/*.patch): OOM events on cgroup v2 — upstream watches only cgroup v1's memory.oom_control.
  for p in /patches/*.patch; do git apply \$p; done
  cargo build -q --release --bin containerd-shim-runc-v2-rs
  strip target/release/containerd-shim-runc-v2-rs
  cp target/release/containerd-shim-runc-v2-rs /out/containerd-shim-runc-v2-rs-$ARCH
  git rev-parse HEAD > /out/containerd-shim-runc-v2-rs-$ARCH.commit
"
ls -la "out/containerd-shim-runc-v2-rs-$ARCH"
