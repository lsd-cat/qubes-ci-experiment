#!/bin/bash
# Stage the Qubes-under-nested-KVM experiment into $1 (default /work):
# ISO (verified), 80G sparse disk, kickstart volume. Then print the boot command.
set -euo pipefail
WORK="${1:-/work}"
ISO_URL="https://mirrors.edge.kernel.org/qubes/iso/Qubes-R4.3.1-x86_64.iso"
CI_DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$WORK"

# --- ISO (resumable) ---
iso_ok() {
  curl -sL "$ISO_URL.DIGESTS" | grep -E "^[0-9a-f]{64} " | sed 's| .*| qubes.iso|' | sha256sum -c - >/dev/null 2>&1
}
if ! iso_ok; then
  echo ">> downloading ISO (~8GB, resuming if partial)"
  curl -sL -C - --retry 10 --retry-all-errors -o qubes.iso "$ISO_URL"
  iso_ok || { echo "ISO digest mismatch"; exit 1; }
fi
echo ">> ISO verified"

# --- target disk (sparse) ---
[ -f qubes.qcow2 ] || qemu-img create -f qcow2 qubes.qcow2 80G

# --- kickstart volume (ext4, label KS) ---
if [ ! -f ks.img ]; then
  dd if=/dev/zero of=ks.img bs=1M count=16 status=none
  mkfs.ext4 -q -F -L KS ks.img
  mkdir -p /tmp/ksmnt
  sudo mount -o loop ks.img /tmp/ksmnt
  sudo cp "$CI_DIR/ks.cfg" /tmp/ksmnt/ks.cfg
  sudo umount /tmp/ksmnt
fi

echo
echo ">> staged in $WORK. Boot the installer with:"
echo "   $CI_DIR/boot-qemu.sh $WORK install"
echo ">> then connect to the serial console:"
echo "   socat -,raw,echo=0 UNIX-CONNECT:$WORK/serial.sock"
