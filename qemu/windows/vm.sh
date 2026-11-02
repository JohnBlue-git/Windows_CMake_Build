#!/usr/bin/env bash
# Run the Windows build VM and build CMake_DLL inside it (replaces docker build/run).
#
# The base image is never modified: the VM always runs on a copy-on-write
# overlay (.run/overlay.qcow2) that is backed by the base image.
#
# Usage:
#   ./vm.sh build [Release|Debug]  fresh overlay -> boot -> build -> fetch -> shut down
#   ./vm.sh start                  boot the VM in the background (keeps existing overlay)
#   ./vm.sh ssh [command...]       PowerShell session (or one command) in the VM
#   ./vm.sh stop                   shut the VM down cleanly
#   ./vm.sh reset                  stop and discard the overlay (back to the clean base)
#   ./vm.sh status
#
# Environment overrides:
#   IMAGE      base qcow2   (default: output/cmake-dll-win.qcow2)
#   VM_CPUS    default: nproc (max 8)
#   VM_MEMORY  MiB, default: 8192
#   SSH_PORT   host port forwarded to guest 22   (default: 2222)
#   VNC        VNC display on 127.0.0.1, e.g. 1 -> port 5901 (default: off)
#   OUT_DIR    where build artifacts go          (default: <repo>/out/windows)
#   KEEP=1     with 'build': leave the VM running afterwards
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

IMAGE="${IMAGE:-$HERE/output/cmake-dll-win.qcow2}"
RUN_DIR="$HERE/.run"
OVERLAY="$RUN_DIR/overlay.qcow2"
PIDFILE="$RUN_DIR/qemu.pid"
KEY="$HERE/keys/id_ed25519"
SSH_PORT="${SSH_PORT:-2222}"
OUT_DIR="${OUT_DIR:-$REPO/out/windows}"

cpus_default=$(nproc); (( cpus_default > 8 )) && cpus_default=8
VM_CPUS="${VM_CPUS:-$cpus_default}"
VM_MEMORY="${VM_MEMORY:-8192}"

SSH_OPTS=(-i "$KEY" -p "$SSH_PORT"
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes)
SCP_OPTS=(-i "$KEY" -P "$SSH_PORT"
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o BatchMode=yes)
TARGET="Administrator@127.0.0.1"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

is_running() {
    [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

vm_ssh() { ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }

wait_for_ssh() {
    log "Waiting for the VM to accept ssh on port $SSH_PORT..."
    for _ in $(seq 1 120); do
        if vm_ssh 'exit 0' 2>/dev/null; then return 0; fi
        is_running || die "QEMU exited during boot."
        sleep 5
    done
    die "VM did not become reachable over ssh within 10 minutes."
}

cmd_start() {
    if is_running; then log "VM already running (pid $(cat "$PIDFILE"))."; return; fi
    [[ -f "$IMAGE" ]] || die "base image not found: $IMAGE (run ./build-image.sh, or set IMAGE=...)"
    [[ -f "$KEY" ]]   || die "ssh key not found: $KEY (it is created by ./build-image.sh)"
    mkdir -p "$RUN_DIR"
    if [[ ! -f "$OVERLAY" ]]; then
        qemu-img create -q -f qcow2 -b "$(realpath "$IMAGE")" -F qcow2 "$OVERLAY"
    fi

    local display=(-display none)
    [[ -n "${VNC:-}" ]] && display+=(-vnc "127.0.0.1:${VNC}")

    log "Starting VM (cpus=$VM_CPUS, memory=${VM_MEMORY}M, ssh=127.0.0.1:$SSH_PORT)"
    # Devices must match windows.pkr.hcl: i440fx machine, IDE disk, e1000 NIC.
    qemu-system-x86_64 \
        -name cmake-dll-win \
        -machine pc,accel=kvm -cpu host \
        -smp "$VM_CPUS" -m "$VM_MEMORY" \
        -drive file="$OVERLAY",if=ide,format=qcow2,cache=writeback \
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$SSH_PORT"-:22 \
        -device e1000,netdev=n0 \
        -rtc base=utc \
        "${display[@]}" \
        -daemonize -pidfile "$PIDFILE"
    wait_for_ssh
    log "VM is up. Connect with: $0 ssh"
}

cmd_stop() {
    if ! is_running; then log "VM is not running."; rm -f "$PIDFILE"; return; fi
    local pid; pid=$(cat "$PIDFILE")
    log "Shutting down VM..."
    vm_ssh 'Stop-Computer -Force' 2>/dev/null || true
    for _ in $(seq 1 60); do
        kill -0 "$pid" 2>/dev/null || { rm -f "$PIDFILE"; log "VM stopped."; return; }
        sleep 2
    done
    log "Clean shutdown timed out; killing QEMU."
    kill "$pid" 2>/dev/null || true
    rm -f "$PIDFILE"
}

cmd_reset() {
    cmd_stop
    rm -f "$OVERLAY"
    log "Overlay discarded; next start uses the clean base image."
}

cmd_status() {
    if is_running; then echo "running (pid $(cat "$PIDFILE"), ssh 127.0.0.1:$SSH_PORT)"; else echo "stopped"; fi
    [[ -f "$OVERLAY" ]] && qemu-img info "$OVERLAY" | grep -E 'disk size|backing file:' || true
}

cmd_build() {
    local config="${1:-Release}"
    [[ "$config" =~ ^(Release|Debug|RelWithDebInfo|MinSizeRel)$ ]] || die "unknown config: $config"

    BUILD_TMP=$(mktemp -d)
    STARTED_BY_BUILD=0
    trap on_build_exit EXIT
    local tmp="$BUILD_TMP"

    if ! is_running; then
        rm -f "$OVERLAY"          # fresh, clean VM for every build
        STARTED_BY_BUILD=1
        cmd_start
    fi

    log "Packing sources"
    tar -C "$REPO" -cf "$tmp/src.tar" \
        --exclude=./.git --exclude=./build --exclude=./out --exclude=./qemu \
        .

    log "Copying sources into the VM"
    scp "${SCP_OPTS[@]}" "$tmp/src.tar" "$HERE/scripts/guest-build.ps1" "$TARGET:"

    log "Building ($config) inside the VM"
    vm_ssh "powershell -NoProfile -ExecutionPolicy Bypass -File guest-build.ps1 -Config $config"

    log "Fetching artifacts to $OUT_DIR"
    scp "${SCP_OPTS[@]}" "$TARGET:artifacts.tar" "$tmp/artifacts.tar"
    rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
    tar -xf "$tmp/artifacts.tar" -C "$OUT_DIR"
    ls -l "$OUT_DIR"
    log "Done."
}

# Clean up after 'build', including when it fails: remove temp files and shut
# down the VM if this build started it (unless KEEP=1).
on_build_exit() {
    local rc=$?
    rm -rf "${BUILD_TMP:-}"
    if [[ "${STARTED_BY_BUILD:-0}" == 1 && "${KEEP:-0}" != 1 ]]; then
        cmd_stop || true
    fi
    (( rc == 0 )) || echo "build failed (exit $rc). Re-run with KEEP=1 to inspect the VM via ./vm.sh ssh" >&2
    exit "$rc"
}

cmd_ssh() {
    is_running || die "VM is not running (./vm.sh start)."
    if [[ $# -eq 0 ]]; then
        ssh -t "${SSH_OPTS[@]/BatchMode=yes/BatchMode=no}" "$TARGET"
    else
        vm_ssh "$@"
    fi
}

case "${1:-}" in
    build)  shift; cmd_build "$@" ;;
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    reset)  cmd_reset ;;
    status) cmd_status ;;
    ssh)    shift; cmd_ssh "$@" ;;
    *) sed -n '2,24p' "$0"; exit 1 ;;
esac
