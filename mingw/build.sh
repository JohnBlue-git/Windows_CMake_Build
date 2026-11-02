#!/usr/bin/env bash
# Cross-compile Windows_CMake_Build for Windows x64 with MinGW-w64 inside Docker.
# Runs on a Linux host without KVM; output goes to out/mingw/.
#
# Usage:
#   ./mingw/build.sh [Release|Debug|RelWithDebInfo|MinSizeRel]
#
# Environment overrides:
#   IMAGE    docker image tag          (default: cmake-dll-mingw)
#   OUT_DIR  where artifacts are copied (default: <repo>/out/mingw)
#
# Then run the result on Windows:  ./winvm/vm.sh test
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

CONFIG="${1:-Release}"
IMAGE="${IMAGE:-cmake-dll-mingw}"
OUT_DIR="${OUT_DIR:-$REPO/out/mingw}"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

[[ "$CONFIG" =~ ^(Release|Debug|RelWithDebInfo|MinSizeRel)$ ]] || die "unknown config: $CONFIG"
command -v docker >/dev/null || die "'docker' not found."

log "Building docker image $IMAGE"
docker build -q -t "$IMAGE" "$HERE" >/dev/null

log "Building ($CONFIG) with MinGW-w64"
# Run as the host user so build/ and out/ are not owned by root.
docker run --rm --user "$(id -u):$(id -g)" -v "$REPO:/src" "$IMAGE" sh -euc "
    cmake -S /src -B /src/build/mingw -G Ninja \
          -DCMAKE_BUILD_TYPE=$CONFIG \
          -DCMAKE_TOOLCHAIN_FILE=/src/cmake/toolchains/mingw-w64-x86_64.cmake
    cmake --build /src/build/mingw --parallel
"

log "Copying artifacts to $OUT_DIR"
rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
cp "$REPO/build/mingw/bin/"*.exe "$REPO/build/mingw/bin/"*.dll "$OUT_DIR/"
ls -l "$OUT_DIR"
log "Done."
