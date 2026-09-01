# qubes-ci-experiment

Can Qubes OS run under nested KVM on a GitHub-hosted runner?

This repo stages the experiment. The recipe is ported from a working Qubes 4.3.1
deployment under Proxmox/KVM (Zen4 host); the open question on GHA is the extra
nesting level: Azure hypervisor → runner VM → our KVM → Xen → qubes. PV dom0 will
boot; whether PVH/HVM qubes start is what we're here to find out.

## Run it

1. Actions → **debug-shell** → Run workflow (`download_iso: true`).
2. The job maximizes disk (~100GB at `/work`), probes the runner (Azure `vmSize`,
   CPU flavor, `/dev/kvm`), installs QEMU, downloads + verifies the ISO, and drops
   into a **tmate** session — grab the `ssh ...@tmate.io` line from the log.
3. In that shell:

```sh
# unattended install (~20-40 min; QEMU exits when done thanks to ks `poweroff`)
repo/ci/boot-qemu.sh /work install &
socat -,raw,echo=0 UNIX-CONNECT:/work/serial.sock     # watch it go

# boot the installed system
repo/ci/boot-qemu.sh /work run &
socat -,raw,echo=0 UNIX-CONNECT:/work/serial.sock
# LUKS passphrase: qubesdev   -> getty on hvc0 -> login user/qubesdev
```

4. The actual experiment, over that serial login:

```sh
sudo qvm-template install --nogpgcheck /var/lib/qubes/template-packages/qubes-template-fedora-*.rpm
sudo qubesctl saltutil.sync_all
sudo qubesctl state.sls qvm.sys-net    # then qvm.sys-firewall, qvm.vault, ...
qvm-start vault                         # <- THE test: PVH under double-nested virt
qvm-run -p vault 'echo it works'
```

If `qvm-start` works, Qubes-on-GHA is real and the next step is turning this into an
unattended workflow (install once, cache/artifact the qcow2, boot + run tests per push).

## Baked-in pitfalls (already handled, don't undo)

- CPU: Intel runners get `host,+vmx,+invtsc`; AMD get `EPYC-Rome,+svm,+npt,+nrip-save,+invtsc`
  (raw `host` on recent AMD triple-faults the PV dom0 kernel right after "Poking KASLR").
- `-machine q35,kernel-irqchip=split` + emulated `intel-iommu`: without a vIOMMU libxl
  refuses PCI passthrough. (With slirp networking sys-net has no PCI NIC anyway, but the
  IOMMU also provides interrupt remapping and keeps the config identical to the reference.)
- NIC is `e1000`, never `e1000e` (MSI-X heap-corrupts the sys-net stubdomain QEMU) —
  relevant once a NIC is passed through; harmless-but-consistent with slirp.
- Kickstart: `autopart --encrypted --passphrase=...` (avoids an interactive LUKS prompt),
  `%post` adds the user to `qubes`/`wheel` (empty `qubes` group crashes qubesd), makes the
  serial console persistent via /etc/default/grub, and disables the graphical Initial Setup.
- Direct multiboot (`-kernel xen.gz -initrd "vmlinuz ...,initrd.img"`) sidesteps driving
  the ISO's GRUB menu with sendkey.
- The emulated serial drops characters on fast paste: type/send < ~100 chars per line.

Reference: the full deploy guide + failure catalogue lives in the origin deployment's
`DEPLOY-QUBES-ON-PROXMOX.md`.
