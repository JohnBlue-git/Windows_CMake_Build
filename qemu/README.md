# QEMU build VM (Windows)

This replaces the old `docker/` setup. A Packer template installs Windows Server
2022 (Server Core) into a qcow2 disk without any manual steps, then installs the
same toolchain the Windows Dockerfile used: VS 2022 C++ Build Tools and the
CMake bundled with VS. It also installs OpenSSH so the host can copy sources in
and fetch build output.

```
qemu/windows/
├── iso-kit/                 Windows-PC kit: Prepare-Payload / Build-CustomIso / Clean-Workdir -> custom ISO, see iso-kit/README.md
├── windows.pkr.hcl          Packer template (QEMU builder)
├── autounattend.pkrtpl.xml  unattended Windows Setup answers (served on floppy A:)
├── scripts/
│   ├── setup-winrm.ps1        first logon: enable WinRM for Packer
│   ├── install-openssh.ps1    sshd + host public key for Administrator
│   ├── install-buildtools.ps1 VS 2022 Build Tools + CMake
│   ├── verify-toolchain.ps1   fails the image build if cmake/MSVC are missing
│   └── guest-build.ps1        runs inside the VM for each project build
├── build-image.sh           one-time: ISO -> output/cmake-dll-win.qcow2
└── vm.sh                    build / start / ssh / stop / reset
```

## What goes in Git and what doesn't

| In Git (small, reviewable) | Not in Git (see `.gitignore`) |
|---|---|
| Packer template, answer file, PowerShell scripts, `vm.sh` | Windows ISO (`iso/`) |
| | Built base image (`output/*.qcow2`, ~15–25 GB uncompressed, ~8–12 GB compressed) |
| | Per-run overlay disk (`.run/`) |
| | VM ssh key (`keys/`) |

The qcow2 is not committed to GitHub for three reasons:

- It's too large. GitHub rejects files over 100 MB, Git LFS caps files at 2 GB on
  most plans, and release assets are limited to 2 GB each.
- A disk image containing Windows is a copy of Windows. Redistributing it,
  including in a private repo, depends on your Microsoft license terms, and
  evaluation media generally can't be redistributed.
- The image contains the VM's ssh key and Administrator password.

Instead, the image is reproducible: anyone can rebuild it with
`build-image.sh`. To avoid rebuilding on each machine, put one copy on a shared
disk or NAS. `vm.sh` only reads the base image, because each run writes to its
own overlay, so several users can share one base file:

```sh
IMAGE=/srv/vm-images/cmake-dll-win.qcow2 ./qemu/windows/vm.sh build
```

## Host setup (Ubuntu/Debian, e.g. 192.168.11.76)

```sh
# QEMU + KVM
sudo apt install -y qemu-system-x86 qemu-utils
sudo usermod -aG kvm "$USER"        # log out/in afterwards
ls -l /dev/kvm                      # must exist (VT-x/AMD-V enabled in BIOS)

# Packer (HashiCorp apt repo)
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y packer
```

Disk space: about 40 GB free during the image build.

## 1. Get the Windows ISO

**Recommended: custom ISO.** Build it on a Windows PC with
[`windows/iso-kit`](windows/iso-kit/README.md). It contains one edition, has
unneeded components removed, and installs MSVC, CMake and Ninja offline during
Setup. The result is a ~6 GB ISO (built from the Server 2022 evaluation ISO).
Copy `CMakeDLL-WS2022-custom.iso` plus its `.sha256` and
`.manifest.json` into `qemu/windows/iso/`, then check it on the Linux host with
`cd qemu/windows/iso && sha256sum -c CMakeDLL-WS2022-custom.iso.sha256`.
`build-image.sh` picks it up automatically.

**Alternative: stock ISO.** Download **Windows Server 2022 (ISO, English,
64-bit)** from the Microsoft Evaluation Center, or use your licensed media, and
save it as `qemu/windows/iso/windows-server-2022.iso`. Packer then downloads
and installs the Build Tools during the image build.

If you use different media, check the image names inside it and pass the one
you want:

```sh
sudo apt install -y wimtools
7z e -o/tmp/wim windows-server-2022.iso sources/install.wim && wiminfo /tmp/wim/install.wim | grep ^Name
WIN_IMAGE_NAME="Windows Server 2022 SERVERSTANDARDCORE" ./qemu/windows/build-image.sh
```

## 2. Build the base image (once)

```sh
./qemu/windows/build-image.sh                # or: build-image.sh /path/to.iso
```

This takes about 1–2 hours. Most of the time goes to Windows Setup and the
Build Tools download. The build runs headless. To watch it, connect a VNC
viewer to the port Packer prints (127.0.0.1:59xx). From another machine, use an
ssh tunnel: `ssh -L 5900:127.0.0.1:5900 yujen@192.168.11.76`.

Useful overrides: `WIN_ISO_SHA256`, `WIN_PRODUCT_KEY`, `WIN_ADMIN_PASSWORD`,
`VM_CPUS`, `VM_MEMORY`, `HEADLESS=false`, `FORCE=1`, `PACKER_LOG=1`.

## 3. Build the project

```sh
./qemu/windows/vm.sh build            # Release; or: vm.sh build Debug
ls out/windows/                       # ThreadDemo.exe, MyLibrary.dll, ...
```

`vm.sh build` creates a fresh overlay on the clean base image, boots the VM,
copies the sources in, runs `cmake` / `cmake --build` with MSVC, runs
`ThreadDemo.exe`, copies the Release output back to `out/windows/`, and shuts
the VM down. Each build starts from the same clean state, as `docker build`
did.

Interactive use:

```sh
./qemu/windows/vm.sh start            # boot (VNC=1 to also expose 127.0.0.1:5901)
./qemu/windows/vm.sh ssh              # PowerShell in the VM
./qemu/windows/vm.sh stop
./qemu/windows/vm.sh reset            # discard all changes made in the VM
```

## Notes

- **Evaluation expiry:** the evaluation edition runs for 180 days. After that,
  run `build-image.sh` again (`FORCE=1`), or build with a licensed ISO and
  `WIN_PRODUCT_KEY`.
- **Devices:** the VM uses an IDE disk and an e1000 NIC, so Windows needs no
  extra drivers. `vm.sh` must keep the same devices as `windows.pkr.hcl`.
- **Security:** WinRM (HTTP/Basic) and sshd are reachable only through QEMU's
  user-mode network forwards on 127.0.0.1. Change the default
  `WIN_ADMIN_PASSWORD` if the image will be shared.
- **Linux builds** don't need a VM: build natively as described in the
  top-level README.
