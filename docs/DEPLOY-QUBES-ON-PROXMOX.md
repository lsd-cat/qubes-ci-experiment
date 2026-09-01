# Qubes OS 4.3 on Proxmox (nested KVM) — quick deploy guide

Tested: Proxmox 9 / QEMU 11 on AMD Zen4, Qubes R4.3.1. Nested virt must be on
(`cat /sys/module/kvm_amd/parameters/nested` → `1`; Intel: `kvm_intel/parameters/nested`).
Budget ≥12GB RAM and ≥80GB disk for the guest.

## 1. Get the ISO

```sh
cd /var/lib/vz/template/iso
wget https://mirrors.edge.kernel.org/qubes/iso/Qubes-R4.3.1-x86_64.iso
wget -qO- https://mirrors.edge.kernel.org/qubes/iso/Qubes-R4.3.1-x86_64.iso.DIGESTS | grep -E "^[0-9a-f]{64} " | sha256sum -c -
```

## 2. Create the VM (every flag matters)

```sh
qm create 104 --name qubes-dev --memory 12288 --balloon 0 --cores 4 \
  --machine q35 --ostype l26 --scsihw virtio-scsi-single \
  --virtio0 local-lvm:80 --net0 e1000,bridge=vmbr1,firewall=1 \
  --vga std --serial0 socket \
  --boot order='ide2;virtio0' --ide2 local:iso/Qubes-R4.3.1-x86_64.iso,media=cdrom
qm set 104 --args "-machine kernel-irqchip=split -cpu EPYC-Rome,+svm,+npt,+nrip-save,+invtsc -device intel-iommu,intremap=on,caching-mode=on"
```

Why (learned the hard way — see pitfalls):
- **CPU `EPYC-Rome,+svm,+npt`**, never `host` on Zen4: host passthrough triple-faults
  the PV dom0 kernel instantly (silent reboot loop after "Poking KASLR"). `+svm,+npt`
  or the installer reports HVM/HAP missing and no qube will ever start.
  (Intel hosts: mirror the Qubes openQA setup, `-cpu host,+vmx,+invtsc`.)
- **`kernel-irqchip=split` + emulated `intel-iommu`**: without a vIOMMU, libxl refuses
  PCI passthrough ("passthrough not supported on this platform") → sys-net gets no NIC.
- **NIC = plain `e1000`**, not e1000e/virtio: e1000e's MSI-X corrupts the heap of the
  sys-net stubdomain QEMU (xen_pt bug) and the VM won't start.
- SeaBIOS + `vga std` are what Qubes' own openQA uses; don't switch to OVMF/virtio-gpu.

## 3. Install

1. Open the Proxmox noVNC console, boot "Install Qubes OS".
2. An "Unsupported Hardware Detected" warning appears (no *real* IOMMU) — continue.
3. Default partitioning (LVM thin + LUKS). Remember the passphrase: you'll type it in the
   console at **every boot**.
4. Create the user in the installer GUI (this also puts it in the `qubes` group — do not
   skip it; an empty `qubes` group crashes qubesd).
5. Reboot into Initial Setup. **Uncheck "Use a qube to hold all USB controllers"**
   (no IOMMU isolation anyway, and sys-usb can steal the emulated USB input controller).
   Keep the rest default. This takes a while (template unpacking).
6. sys-net: if it fails to start, set `qvm-prefs sys-net virt_mode hvm` and make sure the
   PCI NIC is assigned with options:
   `qvm-pci assign --required -o no-strict-reset=true -o permissive=true sys-net dom0:<port>`
7. No DHCP on your bridge? Set a static IP in sys-net via Network Manager (persists).

Done. App qubes run PVH, sys-net runs HVM, dom0 is PV — the normal Qubes layout.

## Pitfalls (symptoms → cause)

| Symptom | Cause / fix |
|---|---|
| VM silently reboots right after GRUB | CPU model — use EPYC-Rome (§2) |
| Installer: "missing HVM/AMD-V" | add `+svm,+npt` to -cpu |
| sys-net: "passthrough not supported on this platform" | add the vIOMMU (§2) |
| sys-net stubdom dies, "malloc_consolidate" in guest-sys-net-dm.log | NIC must be e1000 |
| "Pci device ...:0x10d3... not available" after changing NIC model | stale assignment: stop qubesd, delete the `<device>` line in /var/lib/qubes/qubes.xml, restart, re-assign |
| qubesd dies with IndexError gr_mem[0] | `qubes` group empty — `usermod -aG qubes,wheel <user>` |

---

## Appendix — automation & remote access

**Serial console to dom0** (scriptable shell access): with `serial0: socket` set, patch the
installed GRUB (`/boot/grub2/grub.cfg`, better also `/etc/default/grub`):
Xen line: `console=com1,vga com1=115200,8n1` (replacing `console=none`);
kernel line: `console=tty0 console=hvc0 plymouth.enable=0 rd.plymouth=0`.
Now the LUKS prompt and a getty appear on serial. On the host:

```sh
tmux new -d -s vmserial "socat STDIO,raw,echo=0 UNIX-CONNECT:/var/run/qemu-server/104.serial0"
tmux send-keys -t vmserial 'qvm-ls' Enter ; tmux capture-pane -t vmserial -p | tail
```

One client at a time. **The emulated serial drops characters on fast paste — keep each
sent line under ~100 chars.** Expose as TCP for other machines:
`socat TCP-LISTEN:7104,bind=<ip>,fork,reuseaddr UNIX-CONNECT:/var/run/qemu-server/104.serial0`
(wrap in a systemd unit with `Restart=always`).

**VNC**: Proxmox already runs a VNC server per VM on a unix socket. Set a static password
and forward it:

```sh
printf 'set_password vnc PASS\nexpire_password vnc never\n' | qm monitor 104
socat TCP-LISTEN:5904,bind=<ip>,fork,reuseaddr UNIX-CONNECT:/var/run/qemu-server/104.vnc
```

Caveat: opening the Proxmox web console overwrites the password — rerun the first command.

**Headless GUI automation** (poor man's openQA): screenshots via
`printf 'screendump /tmp/s.ppm\n' | qm monitor 104` (convert ppm→png), keystrokes via
`qm sendkey 104 <spec>` (ret, tab, spc, esc, arrows, ctrl-alt-f7, alt-d, shift-a…).
Keyboard navigation works in GRUB, anaconda and GTK (Tab/Space/Alt-mnemonics);
QEMU-monitor *mouse* events never reach X — don't bother.

**Unattended install**: anaconda kickstart works — put `ks.cfg` on a small ext4 volume
labeled `KS`, attach it, boot with `inst.ks=hd:LABEL=KS:/ks.cfg`. Two Qubes-specific traps:
`unsupported_hardware` is not a valid command in Qubes' anaconda, and a kickstart-created
user is NOT added to the `qubes`/`wheel` groups (see pitfalls). Template install +
default qubes can then be done over serial:
`qvm-template install --nogpgcheck /var/lib/qubes/template-packages/<t>.rpm`, then
`qubesctl saltutil.sync_all` and `qubesctl state.sls qvm.sys-net` (etc.).

**Template it**: once happy, `qm clone 104 900 --full --name qubes-tmpl && qm template 900`.
Clones share the LUKS passphrase and sys-net's static IP — change the IP before running
two clones at once.
