#!/usr/bin/env bash
# Build the Windows build-VM base image (qcow2) with Packer + QEMU/KVM.
# Run once on the Linux host (e.g. 192.168.11.76); takes roughly 1-2 hours.
#
# Usage:
#   ./build-image.sh [path/to/iso]
#
# ISO selection (first match wins):
#   1. the argument, 2. $WIN_ISO,
#   3. iso/CMakeDLL-WS2022-custom.iso  (custom ISO from iso-kit/Build-CustomIso.ps1)
#   4. iso/windows-server-2022.iso     (stock Microsoft ISO)
# If <iso>.sha256 exists it is verified; if <name>.manifest.json exists the ISO
# is treated as an iso-kit custom ISO (single image -> selected by index 1).
#
# Environment overrides:
#   WIN_ISO_SHA256   ISO sha256          (default: from <iso>.sha256, else not verified)
#   WIN_IMAGE_NAME   install.wim image   (default: Windows Server 2022 SERVERSTANDARDCORE)
#   WIN_IMAGE_INDEX  select image by index instead of name
#   WIN_PRODUCT_KEY  product key         (default: none, for evaluation media)
#   WIN_ADMIN_PASSWORD  Administrator password inside the VM
#   VM_CPUS / VM_MEMORY  resources used during the build
#   HEADLESS=false   show the QEMU window (otherwise watch via VNC 127.0.0.1:5900-5910)
#   FORCE=1          overwrite an existing output/ directory
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

if [[ -n "${1:-}" ]]; then ISO="$1"
elif [[ -n "${WIN_ISO:-}" ]]; then ISO="$WIN_ISO"
elif [[ -f "$HERE/iso/CMakeDLL-WS2022-custom.iso" ]]; then ISO="$HERE/iso/CMakeDLL-WS2022-custom.iso"
else ISO="$HERE/iso/windows-server-2022.iso"
fi
KEY="$HERE/keys/id_ed25519"

die() { echo "error: $*" >&2; exit 1; }

# --- prerequisites -----------------------------------------------------------
for cmd in packer qemu-system-x86_64 qemu-img ssh-keygen; do
    command -v "$cmd" >/dev/null || die "'$cmd' not found. See qemu/README.md (host setup)."
done
[[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm not accessible. Enable VT-x/AMD-V and add yourself to the 'kvm' group."
[[ -f "$ISO" ]] || die "Windows ISO not found: $ISO
Either copy the custom ISO built by iso-kit/Build-CustomIso.ps1 to
qemu/windows/iso/CMakeDLL-WS2022-custom.iso (see iso-kit/README.md), or save the
stock Windows Server 2022 ISO as qemu/windows/iso/windows-server-2022.iso."

if [[ -n "${WIN_ADMIN_PASSWORD:-}" && "$WIN_ADMIN_PASSWORD" =~ [\<\>\&\"\'] ]]; then
    die "WIN_ADMIN_PASSWORD must not contain < > & \" ' (it is embedded in XML)."
fi

if [[ -d output && "${FORCE:-0}" != 1 ]]; then
    die "output/ already exists. Remove it or re-run with FORCE=1."
fi

# --- ssh key the host uses to log into the VM -------------------------------
if [[ ! -f "$KEY" ]]; then
    mkdir -p "$(dirname "$KEY")"
    ssh-keygen -q -t ed25519 -N '' -C "cmake-dll-win-vm" -f "$KEY"
    echo "Generated VM ssh key: $KEY"
fi

# --- build -------------------------------------------------------------------
checksum="none"
if [[ -n "${WIN_ISO_SHA256:-}" ]]; then
    checksum="sha256:${WIN_ISO_SHA256}"
elif [[ -f "$ISO.sha256" ]]; then
    checksum="sha256:$(awk '{print tolower($1); exit}' "$ISO.sha256")"
    echo "Using checksum from $ISO.sha256"
fi

image_index="${WIN_IMAGE_INDEX:-0}"
manifest="${ISO%.iso}.manifest.json"
if [[ "$image_index" == 0 && -f "$manifest" ]]; then
    image_index=1
    echo "Custom ISO detected ($manifest): selecting image index 1"
fi

args=(
    -var "iso_url=$(realpath "$ISO")"
    -var "iso_checksum=$checksum"
    -var "ssh_public_key_file=$KEY.pub"
    -var "headless=${HEADLESS:-true}"
    -var "image_index=$image_index"
)
[[ -n "${WIN_IMAGE_NAME:-}"     ]] && args+=(-var "image_name=$WIN_IMAGE_NAME")
[[ -n "${WIN_PRODUCT_KEY:-}"    ]] && args+=(-var "product_key=$WIN_PRODUCT_KEY")
[[ -n "${WIN_ADMIN_PASSWORD:-}" ]] && args+=(-var "admin_password=$WIN_ADMIN_PASSWORD")
[[ -n "${VM_CPUS:-}"            ]] && args+=(-var "cpus=$VM_CPUS")
[[ -n "${VM_MEMORY:-}"          ]] && args+=(-var "memory=$VM_MEMORY")
[[ "${FORCE:-0}" == 1 ]] && args+=(-force)

packer init .
packer validate "${args[@]}" .
PACKER_LOG="${PACKER_LOG:-0}" packer build "${args[@]}" .

echo
echo "Base image ready: $HERE/output/cmake-dll-win.qcow2"
qemu-img info "$HERE/output/cmake-dll-win.qcow2" | sed -n '1,6p'
echo "Next: ./vm.sh build"
