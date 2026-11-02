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

## Build in a QEMU Windows VM

The Windows build runs in a QEMU/KVM virtual machine on a Linux host. A Packer
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