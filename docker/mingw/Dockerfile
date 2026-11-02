# Fixed Linux build environment: CMake + Ninja + MinGW-w64 (posix threads).
# Used by docker/mingw/build.sh; the repo is bind-mounted at /src.
FROM ubuntu:24.04

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        cmake ninja-build \
        g++-mingw-w64-x86-64-posix gcc-mingw-w64-x86-64-posix \
        binutils-mingw-w64-x86-64 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
