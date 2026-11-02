# CMake DLL and Thread Demo

A small C++17 project that builds an executable and a shared library with CMake.
On Windows the shared library is a DLL; on Linux it is a `.so`. The executable
starts a `std::thread` that calls an exported function from the library.

## Build on Linux

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
./build/bin/ThreadDemo
```

## Build on Windows

Run these commands from a Visual Studio Developer PowerShell or a terminal with
the MSVC compiler available:

```powershell
cmake -S . -B build
cmake --build build --config Release
.\build\bin\Release\ThreadDemo.exe
```

The executable and DLL are emitted to the same runtime output directory, so the
Windows loader can find the DLL when starting the executable. The `.lib` import
library is used at link time.

## Cross-compile for Windows with MinGW-w64 (no KVM needed)

The Windows build runs in Docker on the Linux host. MinGW-w64 (posix threads)
cross-compiles the project, and the GCC runtime is linked statically, so the
output needs no extra DLLs. A QEMU Windows VM then runs the result on real
Windows. The VM works without KVM (software emulation, slow).

```sh
# one time: download the official Windows Server 2022 evaluation ISO
#   (Microsoft Evaluation Center) to qemu/windows/iso/windows-server-2022.iso
# one time: build the base image (Windows + OpenSSH only, no compiler)
TOOLCHAIN=0 ./qemu/windows/build-image.sh

# every build: Docker + CMake + Ninja + MinGW-w64 -> out/mingw/
./docker/mingw/build.sh                 # or: build.sh Debug

# test on Windows: clean VM -> copy out/mingw -> run ThreadDemo.exe
./qemu/windows/vm.sh test
```

MinGW and MSVC use different C++ ABIs. Use `libMyLibrary.dll` only with
programs that MinGW-w64 also builds, not with MSVC-built programs. The import
library is `build/mingw/libMyLibrary.dll.a`, not `MyLibrary.lib`.

## Optional: build with MSVC in a QEMU Windows VM

> **Not verified** on the current host (no KVM). The MinGW flow above is the
> verified path. The MSVC scripts are kept for hosts that need MSVC output
> (for example, a DLL that MSVC-built programs link against).

The MSVC build runs in a QEMU virtual machine (KVM if available, TCG otherwise) on a Linux host. A Packer
template defines the VM: Windows Server 2022 Server Core, Visual Studio 2022 C++
Build Tools, CMake, and OpenSSH. Git holds that recipe (`qemu/windows/`), not
the disk image. See [`qemu/README.md`](qemu/README.md) for host setup and
details.

```sh
# one time, on a Windows PC: build the custom ISO (debloated, toolchain embedded)
#   see qemu/windows/iso-kit/README.md, then copy the ISO to qemu/windows/iso/

# one time (~1-2 h): build the base image from the ISO
./qemu/windows/build-image.sh

# every build: clean VM -> MSVC build -> run ThreadDemo.exe -> out/windows/
./qemu/windows/vm.sh build
```

## What to look at

- `src/my_library.h` declares the exported API. The `MYDLL_EXPORTS`
  definition is private to the library target, selecting `dllexport` while the
  library is built and `dllimport` for Windows consumers.
- `src/my_library.cpp` implements the library function.
- `src/main.cpp` links the library and runs the function on a worker thread.
- `CMakeLists.txt` discovers the platform thread library and places runtime
  artifacts together.