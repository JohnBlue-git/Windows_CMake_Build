# Windows VM (`winvm/`)

The VM has two uses:

- **Test MinGW builds** (main flow, verified). `mingw/build.sh` cross-compiles
  on the Linux host; `winvm/vm.sh test` runs the output in the VM.
- **Build with MSVC** inside the VM (`winvm/vm.sh build`). Optional and **not
  verified** on the current host.

See the diagrams in the [top-level README](../README.md#how-it-fits-together)
for how the pieces connect.

## Files

```
winvm/
├── vm.sh                     every run: test / build / start / ssh / stop / reset / status
├── build-image.sh            one time: ISO -> output/cmake-dll-win.qcow2 (runs Packer)
├── qemu-docker/
│   ├── Dockerfile            QEMU 10 (Debian trixie)
│   └── qemu-docker.sh        drop-in qemu-system-x86_64 that runs QEMU 10 in Docker
├── packer/                   image recipe
│   ├── windows.pkr.hcl       Packer template (QEMU builder; builds "base" and "msvc")
│   ├── autounattend.pkrtpl.xml   unattended Windows Setup answers (served on floppy A:)
│   └── provision/            run once, while Packer builds the image
│       ├── setup-winrm.ps1         first logon: enable WinRM for Packer
│       ├── install-openssh.ps1     sshd + host public key for Administrator
│       ├── install-buildtools.ps1  (msvc) VS 2022 Build Tools + CMake
│       └── verify-toolchain.ps1    (msvc) fail the image build if cmake/MSVC is missing
├── guest/                    copied into the VM by vm.sh on each run
│   ├── guest-test.ps1        vm.sh test: unpack out/mingw, run ThreadDemo.exe
│   └── guest-build.ps1       vm.sh build: unpack sources, cmake + MSVC, pack output
├── iso-kit/                  optional, Windows PC: custom ISO (see docs/iso-kit.md)
│
│   local only, not in Git (see .gitignore):
├── iso/                      Windows ISO(s)
├── output/                   base image cmake-dll-win.qcow2
├── keys/                     ssh key the host uses to log in to the VM
└── .run/                     per-run overlay disk, QEMU log and pid
```

## What goes in Git and what doesn't

| In Git (small, reviewable) | Not in Git |
|---|---|
| Packer template, answer file, PowerShell scripts, shell scripts | Windows ISO (`iso/`) |
| | Base image (`output/*.qcow2`, ~3 GB for the MinGW image, more with MSVC) |
| | Per-run overlay (`.run/`) |
| | VM ssh key (`keys/`) |

The qcow2 is not committed because:

- It is too large. GitHub rejects files over 100 MB; Git LFS and release assets
  cap at 2 GB.
- It is a copy of Windows. Redistributing it depends on your Microsoft license
  terms, and evaluation media generally can't be redistributed.
- It contains the VM's ssh public key and the Administrator password.

The image is reproducible with `build-image.sh`. To avoid rebuilding on each
machine, put one copy on a shared disk. `vm.sh` only reads the base image (each
run writes to its own overlay), so several users can share one base file.
**Copy `keys/` together with the image**: the image only accepts that key.

```sh
IMAGE=/srv/vm-images/cmake-dll-win.qcow2 ./winvm/vm.sh test
```

## Host setup (Ubuntu/Debian)

```sh
# Docker (for mingw/ and, without KVM, for QEMU 10)
sudo apt install -y docker.io && sudo usermod -aG docker "$USER"   # log out/in

# QEMU tools (qemu-img is always used on the host)
sudo apt install -y qemu-system-x86 qemu-utils
ls -l /dev/kvm                      # optional; without it QEMU uses TCG in Docker
sudo usermod -aG kvm "$USER"        # only if /dev/kvm exists

# Packer (HashiCorp apt repo), only for build-image.sh
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y packer
```

Disk space: about 40 GB free during the image build.

## 1. Get the Windows ISO

**For MinGW testing: the official ISO.** Download **Windows Server 2022 (ISO,
English, 64-bit)** from the Microsoft Evaluation Center and save it as
`winvm/iso/windows-server-2022.iso`.

**For MSVC (optional): the custom ISO.** Build it on a Windows PC with
[`winvm/iso-kit`](iso-kit.md). Copy `CMakeDLL-WS2022-custom.iso` with its
`.sha256` and `.manifest.json` into `winvm/iso/`, then check it:
`cd winvm/iso && sha256sum -c CMakeDLL-WS2022-custom.iso.sha256`.
`build-image.sh` picks it up automatically. You can also use the official ISO
for MSVC; Packer then downloads the Build Tools during the image build.

If you use different media, list the image names and pass the one you want:

```sh
sudo apt install -y wimtools
7z e -o/tmp/wim windows-server-2022.iso sources/install.wim && wiminfo /tmp/wim/install.wim | grep ^Name
WIN_IMAGE_NAME="Windows Server 2022 SERVERSTANDARDCORE" ./winvm/build-image.sh
```

## 2. Build the base image (once)

```sh
TOOLCHAIN=0 ./winvm/build-image.sh    # MinGW testing: Windows + OpenSSH
./winvm/build-image.sh                # MSVC (optional): + Build Tools
```

`TOOLCHAIN=0` uses the official ISO and skips the Build Tools. Without it, the
custom ISO is preferred if present. The build runs headless. To watch it,
connect a VNC viewer to the port Packer prints (127.0.0.1:59xx). From another
machine, use an ssh tunnel: `ssh -L 5900:127.0.0.1:5900 <user>@<host>`.

Overrides: `WIN_ISO_SHA256`, `WIN_PRODUCT_KEY`, `WIN_ADMIN_PASSWORD`,
`VM_CPUS`, `VM_MEMORY`, `HEADLESS=false`, `FORCE=1`, `PACKER_LOG=1`,
`ACCEL=kvm|tcg`, `QEMU=<binary>`.

**Without KVM**, `build-image.sh` and `vm.sh` use TCG with `-cpu max` and run
QEMU 10 from Docker through `qemu-docker/qemu-docker.sh`. The host's QEMU 6.2
(Ubuntu 22.04) crashes Windows Setup under TCG with
`SYSTEM_THREAD_EXCEPTION_NOT_HANDLED` about 50 s into boot. Set
`QEMU=qemu-system-x86_64` to use a host QEMU that is new enough. The first run
builds the `cmake-dll-qemu` Docker image.

Measured on a host without KVM (8 vCPUs): `TOOLCHAIN=0` image build about
1 hour; `vm.sh test` about 5 minutes (boot, run, shut down). `vm.sh` waits up to
`BOOT_TIMEOUT` seconds for ssh (default 3600 with TCG, 600 with KVM).

## 3. Test a MinGW build

```sh
./mingw/build.sh                 # cross-compile -> out/mingw/
./winvm/vm.sh test               # run out/mingw/ThreadDemo.exe in the VM
```

`vm.sh test` creates a new overlay, boots the VM, copies `out/mingw/` in
(`TEST_DIR=...` to change it), runs `guest/guest-test.ps1`, and shuts the VM
down. To test several builds without a reboot each time, run `vm.sh start`
first; `test` then reuses the running VM and leaves it running.

## 4. Optional: build with MSVC (not verified)

Needs an image built without `TOOLCHAIN=0`.

```sh
./winvm/vm.sh build              # Release; or: vm.sh build Debug
ls out/windows/                  # ThreadDemo.exe, MyLibrary.dll, ...
```

`vm.sh build` creates a new overlay, boots the VM, copies the sources in, runs
`cmake` / `cmake --build` with MSVC, runs `ThreadDemo.exe`, copies the output
back to `out/windows/`, and shuts the VM down.

## Interactive use

```sh
./winvm/vm.sh start              # boot (VNC=1 to also expose 127.0.0.1:5901)
./winvm/vm.sh ssh                # PowerShell in the VM
./winvm/vm.sh status
./winvm/vm.sh stop
./winvm/vm.sh reset              # discard all changes made in the VM
```

`vm.sh` overrides: `IMAGE`, `VM_CPUS`, `VM_MEMORY`, `SSH_PORT` (default 2222),
`VNC`, `OUT_DIR`, `TEST_DIR`, `ACCEL`, `QEMU`, `BOOT_TIMEOUT`, `KEEP=1` (leave
the VM running after `test`/`build`, for example to inspect a failure).

## Notes

- **Evaluation expiry:** the evaluation edition runs for 180 days. After that,
  run `build-image.sh` again (`FORCE=1`), or use a licensed ISO and
  `WIN_PRODUCT_KEY`.
- **Devices:** the VM uses an IDE disk and an e1000 NIC, so Windows needs no
  extra drivers. `vm.sh` must keep the same devices as `packer/windows.pkr.hcl`.
- **Security:** WinRM (HTTP/Basic) and sshd are reachable only through QEMU's
  user-mode forwards on 127.0.0.1. Change the default `WIN_ADMIN_PASSWORD` if
  the image will be shared.
- **Port in use:** if another program already listens on 127.0.0.1:2222, set
  `SSH_PORT`.
