# Windows CMake Build on Linux

A small C++17 project (an executable plus a shared library) and the tooling to
build it **for Windows** and **test it on real Windows**, all from a Linux host.
No Windows PC and no KVM are needed for the main flow.

- `ThreadDemo.exe` starts a `std::thread` that calls an exported function from
  `libMyLibrary.dll`.
- **Build:** MinGW-w64 cross-compiles in a Docker container.
- **Test:** a Windows Server 2022 VM runs the EXE. QEMU runs in a second Docker
  container, so it works without KVM.

## Quick start

```sh
# One time (about 1 hour without KVM): see docs/winvm.md for the ISO download
TOOLCHAIN=0 ./winvm/build-image.sh      # ISO -> winvm/output/cmake-dll-win.qcow2

# Every change
./mingw/build.sh                        # build   -> out/mingw/  (about 1 min)
./winvm/vm.sh test                      # test on Windows        (about 5 min without KVM)
```

Expected end of `vm.sh test`:

```
==> Running ThreadDemo.exe inside the VM
Starting thread demo.
Hello from the shared library on a worker thread.
Thread finished.
==> Done.
```

## How it fits together

### Main flow: MinGW build in Docker, test in a QEMU Windows VM

```mermaid
flowchart LR
    subgraph HOST["Linux host (no KVM needed)"]
        SRC["src/ + CMakeLists.txt"]
        subgraph C1["Docker container: cmake-dll-mingw"]
            MINGW["CMake + Ninja<br/>MinGW-w64 g++ (posix threads)"]
        end
        OUT["out/mingw/<br/>ThreadDemo.exe<br/>libMyLibrary.dll"]
        subgraph C2["Docker container: cmake-dll-qemu"]
            subgraph VM["QEMU 10 VM: Windows Server 2022"]
                RUN["guest-test.ps1<br/>runs ThreadDemo.exe"]
            end
        end
    end
    SRC -->|"1. mingw/build.sh"| MINGW --> OUT
    OUT -->|"2. winvm/vm.sh test<br/>scp over 127.0.0.1:2222"| RUN
```

### Inside the Docker + QEMU environment

`vm.sh` never starts Windows from the base image directly. Each run gets a new
copy-on-write overlay, so every test starts from the same clean Windows.

```mermaid
flowchart TB
    subgraph HOST["Linux host"]
        VMSH["winvm/vm.sh"]
        KEY["winvm/keys/id_ed25519<br/>(ssh key, created by build-image.sh)"]
        BASE[("winvm/output/cmake-dll-win.qcow2<br/>base image: never written, ~3 GB")]
        OVL[("winvm/.run/overlay.qcow2<br/>overlay: new for each run")]
        subgraph CT["Docker: cmake-dll-qemu"]
            QEMU["qemu-system-x86_64 (QEMU 10)<br/>TCG software CPU, -cpu max<br/>IDE disk + e1000 NIC (in-box drivers)"]
            subgraph WIN["Guest: Windows Server 2022 Core"]
                SSHD["OpenSSH server :22"]
                TEST["C:\work\test\ThreadDemo.exe"]
            end
        end
    end
    VMSH -->|"docker run via<br/>qemu-docker/qemu-docker.sh"| QEMU
    QEMU -->|"boots"| SSHD
    QEMU -->|"writes to"| OVL
    OVL -->|"backing file"| BASE
    VMSH -->|"ssh / scp to 127.0.0.1:2222<br/>(QEMU forwards to guest :22)"| SSHD
    KEY -.-> VMSH
    SSHD --> TEST
```

QEMU runs in Docker only on hosts without KVM, because the host's QEMU is too
old for Windows under software emulation (see [docs/winvm.md](docs/winvm.md)).
On a host **with** `/dev/kvm`, `vm.sh` uses the host's QEMU directly.

### What `vm.sh test` does

```mermaid
sequenceDiagram
    participant U as You
    participant V as winvm/vm.sh
    participant Q as QEMU (Docker)
    participant W as Windows VM
    U->>V: ./winvm/vm.sh test
    alt VM not running yet
        V->>V: delete old overlay, create new overlay on the base image
        V->>Q: start QEMU (hostfwd 127.0.0.1:2222 -> guest 22)
        Q->>W: boot Windows
        loop until ssh answers (up to BOOT_TIMEOUT)
            V->>W: ssh exit 0
        end
    else VM already running (vm.sh start)
        V->>W: reuse it
    end
    V->>W: scp test.tar (out/mingw) + guest-test.ps1
    V->>W: ssh powershell guest-test.ps1
    W-->>V: ThreadDemo.exe output and exit code
    opt vm.sh started the VM, and KEEP is not 1
        V->>W: Stop-Computer
        Q-->>V: QEMU exits
    end
    V-->>U: Done (or the error, with exit code)
```

### One time: create the base image

```mermaid
flowchart LR
    ISO["winvm/iso/<br/>windows-server-2022.iso<br/>(Microsoft evaluation ISO)"]
    subgraph PK["build-image.sh + Packer"]
        subgraph CT["Docker (no KVM)"]
            P1["QEMU 10: unattended Windows Setup<br/>(packer/autounattend.pkrtpl.xml)"]
        end
        P2["first logon: provision/setup-winrm.ps1<br/>(from floppy A:)"]
        P3["Packer over WinRM:<br/>provision/install-openssh.ps1<br/>+ host ssh public key"]
        P1 --> P2 --> P3
    end
    ISO --> P1
    P3 --> BASE[("winvm/output/<br/>cmake-dll-win.qcow2")]
```

## Optional flow: build with MSVC inside the VM

> **Not verified** on the current host. Use it only if you need MSVC output,
> for example a DLL that MSVC-built programs link against. MinGW and MSVC use
> different C++ ABIs, so `libMyLibrary.dll` from the main flow works only with
> programs that MinGW-w64 also builds.

```mermaid
flowchart LR
    subgraph PC["Windows PC (optional, once)"]
        KIT["winvm/iso-kit/<br/>Prepare-Payload.ps1<br/>Build-CustomIso.ps1"]
        CISO["CMakeDLL-WS2022-custom.iso<br/>(debloated, MSVC + CMake + Ninja inside)"]
        KIT --> CISO
    end
    STOCK["windows-server-2022.iso<br/>(official)"]
    subgraph HOST["Linux host"]
        IMG["./winvm/build-image.sh<br/>(without TOOLCHAIN=0)<br/>+ VS 2022 Build Tools + CMake"]
        BASE[("cmake-dll-win.qcow2<br/>with MSVC")]
        BUILD["./winvm/vm.sh build<br/>copy sources in -> cmake + MSVC<br/>-> run ThreadDemo.exe"]
        OUTW["out/windows/<br/>ThreadDemo.exe, MyLibrary.dll"]
        IMG --> BASE --> BUILD --> OUTW
    end
    CISO -->|"scp to winvm/iso/<br/>(preferred: offline install)"| IMG
    STOCK -.->|"or: Packer downloads<br/>Build Tools"| IMG
```

```sh
./winvm/build-image.sh       # FORCE=1 to replace an existing MinGW-only image
./winvm/vm.sh build          # Release; or: vm.sh build Debug -> out/windows/
```

### Compare the two flows

| | Main: MinGW + VM test (verified) | Optional: MSVC in VM (not verified) |
|---|---|---|
| Compiler | MinGW-w64 g++ in Docker on Linux | MSVC (VS 2022 Build Tools) in Windows |
| ISO | official evaluation ISO | custom ISO from `winvm/iso-kit/`, or official ISO |
| Image build | `TOOLCHAIN=0 ./winvm/build-image.sh` | `./winvm/build-image.sh` |
| Image contains | Windows + OpenSSH | + VS 2022 Build Tools, CMake |
| Every change | `./mingw/build.sh` then `./winvm/vm.sh test` | `./winvm/vm.sh build` |
| Output | `out/mingw/` (`libMyLibrary.dll`, import lib `.dll.a`) | `out/windows/` (`MyLibrary.dll`, import lib `.lib`) |

## Repository layout

```
.
├── CMakeLists.txt, src/            the C++ project (library + demo executable)
├── cmake/toolchains/               MinGW-w64 toolchain file for cross-compiling
├── mingw/                          STEP 1: build for Windows in Docker
│   ├── Dockerfile                  Ubuntu + CMake + Ninja + MinGW-w64
│   └── build.sh                    -> build/mingw/, out/mingw/
├── winvm/                          STEP 2: Windows VM (test, or optional MSVC build)
│   ├── vm.sh                       every run: test | build | start | ssh | stop | reset
│   ├── build-image.sh              one time: ISO -> output/cmake-dll-win.qcow2
│   └── ...                         full file list: docs/winvm.md
├── docs/
│   ├── winvm.md                    VM host setup, files, options
│   └── iso-kit.md                  custom ISO step by step (Windows PC)
└── build/, out/                    generated, not in Git
```

## Build natively (no Windows needed)

Linux (`.so`):

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
./build/bin/ThreadDemo
```

Windows with MSVC (Developer PowerShell):

```powershell
cmake -S . -B build
cmake --build build --config Release
.\build\bin\Release\ThreadDemo.exe
```

The executable and DLL go to the same output directory, so the Windows loader
finds the DLL when the executable starts.

## What to look at in the code

- `src/my_library.h` declares the exported API. `MYDLL_EXPORTS` is private to
  the library target, so it selects `dllexport` while the library builds and
  `dllimport` for consumers.
- `src/my_library.cpp` implements the library function.
- `src/main.cpp` runs the library function on a worker thread.
- `CMakeLists.txt` finds the platform thread library and puts runtime
  artifacts together in `bin/`.
- `cmake/toolchains/mingw-w64-x86_64.cmake` selects the `-posix` MinGW compiler
  (needed for `std::thread`) and links the GCC runtime statically, so the EXE
  and DLL need no extra DLLs on Windows.
