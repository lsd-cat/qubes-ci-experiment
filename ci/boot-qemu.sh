#!/bin/bash
# Boot the Qubes VM under nested KVM.
#   boot-qemu.sh <workdir> install   # unattended kickstart install (direct kernel boot, no GRUB fiddling)
#   boot-qemu.sh <workdir> run       # boot the installed disk
# Serial console: socat -,raw,echo=0 UNIX-CONNECT:<workdir>/serial.sock
# Monitor (HMP):  socat - UNIX-CONNECT:<workdir>/mon.sock      (screendump, sendkey, ...)
# VNC: 127.0.0.1:5944
set -euo pipefail
WORK="${1:?workdir}"; MODE="${2:?install|run}"
cd "$WORK"
sudo chmod 666 /dev/kvm 2>/dev/null || true

# CPU flags: the exact models matter (see README pitfalls)
if grep -q GenuineIntel /proc/cpuinfo; then
  CPU="host,+vmx,+invtsc"                      # openQA-style Intel config
else
  CPU="EPYC-Rome,+svm,+npt,+nrip-save,+invtsc" # masked model; raw `host` on Zen4 triple-faults dom0
fi

COMMON=(
  -enable-kvm -machine q35,kernel-irqchip=split -cpu "$CPU" -smp 4 -m 10240
  -device intel-iommu,intremap=on,caching-mode=on
  -drive file=qubes.qcow2,if=virtio,format=qcow2
  -netdev user,id=n0 -device e1000,netdev=n0       # e1000, NOT e1000e (xen_pt MSI-X bug); slirp = built-in DHCP
  -vga std -display none -vnc 127.0.0.1:44
  -serial unix:serial.sock,server,nowait
  -monitor unix:mon.sock,server,nowait
)

if [ "$MODE" = install ]; then
  # extract Xen + installer kernel/initrd from the ISO for direct (multiboot) boot
  if [ ! -f xen.gz ]; then
    mkdir -p /tmp/isomnt
    sudo mount -o loop,ro qubes.iso /tmp/isomnt
    cp /tmp/isomnt/images/pxeboot/{xen.gz,vmlinuz,initrd.img} .
    sudo umount /tmp/isomnt
  fi
  # QEMU's multiboot loader can't see through gzip: feed it the raw ELF
  if [ ! -f xen.elf ]; then
    zcat xen.gz > xen.elf
  fi
  exec qemu-system-x86_64 "${COMMON[@]}" \
    -drive file=ks.img,if=virtio,format=raw \
    -cdrom qubes.iso \
    -kernel xen.elf \
    -append "console=com1 com1=115200,8n1 noreboot" \
    -initrd "vmlinuz console=tty0 console=hvc0 inst.repo=hd:LABEL=QUBES-R4-3-1-X86-64 inst.ks=hd:LABEL=KS:/ks.cfg,initrd.img" \
    -no-reboot
    # kickstart ends with `poweroff` -> qemu exits when the install is done
else
  exec qemu-system-x86_64 "${COMMON[@]}"
fi
