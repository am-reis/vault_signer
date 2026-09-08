# Windows VM on Debian via QEMU (CLI), OVMF, and swtpm

A Windows 11 VM on a headless Debian server, driven entirely from the
command line, with UEFI + Secure Boot + a software TPM 2.0 (so
Windows Hello and the WebAuthn platform authenticator work — spec
§6.2's actual target), accessed over SSH + VNC from your Mac.

**Not yet run end-to-end on your actual server** — this is written
from stable, well-documented Debian/QEMU/OVMF/swtpm conventions, not
verified on your specific machine (no access to it from here). Exact
package file paths are called out below with the command to confirm
them yourself before relying on this guide blindly. Debian 11's QEMU
(~5.2) and swtpm/OVMF packages are old but fully adequate for
everything here — nothing below needs a newer version.

## 0. One-time host prerequisites

On the Debian server:

```bash
sudo apt update
sudo apt install qemu-system-x86 qemu-utils ovmf swtpm swtpm-tools cpu-checker
```

Confirm hardware virtualization is actually usable — without this,
QEMU falls back to full software emulation and everything below will
be painfully slow:

```bash
kvm-ok
```

If that reports KVM acceleration can be used, you're set. If not,
stop here and fix that first (BIOS virtualization setting, or — if
this Debian box is itself a VM — nested virtualization needs to be
enabled on its host).

Confirm the exact OVMF firmware file names — these have varied across
Debian releases and packaging changes, so check rather than trust the
path below blindly:

```bash
dpkg -L ovmf | grep -i '\.fd$'
```

You're looking for a `OVMF_CODE...fd` (the read-only firmware) and a
matching `OVMF_VARS...fd` (the writable template for a VM's own UEFI
variables/Secure Boot state). The rest of this guide assumes
`/usr/share/OVMF/OVMF_CODE_4M.ms.fd` (the `.ms` variant has
Microsoft's Secure Boot certificates pre-enrolled, required for
Windows 11 to accept Secure Boot as "on") and
`/usr/share/OVMF/OVMF_VARS_4M.ms.fd` — **substitute whatever `dpkg -L`
actually printed** if it differs.

## 1. Get a Windows 11 ISO

Download from Microsoft directly:
<https://www.microsoft.com/software-download/windows11> (the "Download
Windows 11 Disk Image (ISO)" option). Copy it to the Debian server,
e.g. `/srv/vms/windows/Win11.iso`.

## 2. Create the VM's disk and per-VM UEFI vars

```bash
VMDIR=/srv/vms/windows
mkdir -p "$VMDIR/tpm"

qemu-img create -f qcow2 "$VMDIR/disk.qcow2" 100G

# A per-VM writable copy — never point -drive directly at the
# system's own OVMF_VARS file, every VM needs its own.
cp /usr/share/OVMF/OVMF_VARS_4M.ms.fd "$VMDIR/OVMF_VARS.fd"
```

100G leaves room for Windows + Visual Studio + the .NET/Rust
toolchains without babysitting disk space. Adjust to what the server
actually has free.

## 3. Start the software TPM

Runs as its own background process, listening on a Unix socket QEMU
connects to as `tpm-tis` (the standard PC TPM device Windows expects):

```bash
swtpm socket \
    --tpmstate dir="$VMDIR/tpm" \
    --ctrl type=unixio,path="$VMDIR/tpm/swtpm-sock" \
    --tpm2 \
    --log level=1 &
```

Leave this running for the VM's entire lifetime (start it again after
a host reboot, before starting QEMU).

## 4. First boot: install Windows

Run this inside `tmux` (or `screen`) on the Debian host, so it
survives your SSH session disconnecting:

```bash
tmux new -s winvm
```

Then, deliberately using plain AHCI/SATA for disk and the classic
`e1000` NIC instead of virtio for this first boot — Windows has
built-in drivers for both, so setup needs zero "load driver" detours.
(Switch to virtio later, once Windows is installed, for better
performance — optional, not needed to get a working VM.)

```bash
VMDIR=/srv/vms/windows

qemu-system-x86_64 \
    -enable-kvm -machine q35,accel=kvm -cpu host \
    -smp 4 -m 8G \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.ms.fd \
    -drive if=pflash,format=raw,file="$VMDIR/OVMF_VARS.fd" \
    -drive if=none,id=disk0,file="$VMDIR/disk.qcow2",format=qcow2 \
    -device ahci,id=ahci0 \
    -device ide-hd,drive=disk0,bus=ahci0.0 \
    -drive file=/srv/vms/windows/Win11.iso,media=cdrom \
    -netdev user,id=net0 -device e1000,netdev=net0 \
    -chardev socket,id=chrtpm,path="$VMDIR/tpm/swtpm-sock" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
    -vnc 127.0.0.1:1 \
    -boot menu=on
```

`-vnc 127.0.0.1:1` binds only to the host's loopback interface — the
VM's display is not reachable from the network at all until you tunnel
to it (next step), which is the point: no VNC password needed when the
port was never exposed.

Detach from tmux with `Ctrl-b d` (the VM keeps running); reattach later
with `tmux attach -t winvm`.

## 5. Connect from your Mac: SSH tunnel + VNC

From your Mac, tunnel the VNC port (QEMU's `:1` means display 1, i.e.
TCP port 5901) over SSH:

```bash
ssh -N -L 5901:localhost:5901 <user>@<debian-host>
```

Leave that running, then point any VNC client at `localhost:5901` (macOS's
built-in Screen Sharing app handles VNC directly: Finder → Go → Connect
to Server → `vnc://localhost:5901`).

You should see the QEMU/OVMF boot screen, then the Windows installer.
Install normally. When the installer asks where to install, it should
see the disk directly (no driver loading needed, per the AHCI choice
above).

## 6. Subsequent boots

Once Windows is installed, drop `-boot menu=on` and the installer
`-drive ...Win11.iso,media=cdrom` line — same command otherwise. Save
it as a script for reuse:

```bash
cat > "$VMDIR/run.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
VMDIR=/srv/vms/windows
qemu-system-x86_64 \
    -enable-kvm -machine q35,accel=kvm -cpu host \
    -smp 4 -m 8G \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.ms.fd \
    -drive if=pflash,format=raw,file="$VMDIR/OVMF_VARS.fd" \
    -drive if=none,id=disk0,file="$VMDIR/disk.qcow2",format=qcow2 \
    -device ahci,id=ahci0 \
    -device ide-hd,drive=disk0,bus=ahci0.0 \
    -netdev user,id=net0 -device e1000,netdev=net0 \
    -chardev socket,id=chrtpm,path="$VMDIR/tpm/swtpm-sock" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
    -vnc 127.0.0.1:1
EOF
chmod +x "$VMDIR/run.sh"
```

Remember `swtpm` (step 3) needs to be running before this script —
it doesn't start itself.

## 7. Snapshotting (the actual point of doing this in a VM)

Take a snapshot right after a clean Windows install, and again once
dev tooling (Rust, .NET 8 SDK, Visual Studio) is installed, before
touching anything related to Windows Service registration or the
WebAuthn plugin-authenticator COM registration (spec §6.2) —
exactly the kind of system-state-mutating step worth being able to
revert instantly, per this project's macOS experience.

```bash
# Snapshot (VM must be shut down first — this is offline qcow2
# snapshotting, not QEMU's live-snapshot monitor command):
qemu-img snapshot -c clean-install "$VMDIR/disk.qcow2"
qemu-img snapshot -c dev-tools-installed "$VMDIR/disk.qcow2"

# List snapshots:
qemu-img snapshot -l "$VMDIR/disk.qcow2"

# Revert to one:
qemu-img snapshot -a clean-install "$VMDIR/disk.qcow2"
```

## Later, optional: switch to virtio for performance

Once Windows is installed and you want better disk/network
throughput: download the
[virtio-win ISO](https://github.com/virtio-win/virtio-win-pkg-scripts/blob/master/README.md),
attach it as a second CD-ROM, install the viostor/NetKVM drivers from
Device Manager while still booted on the AHCI/e1000 config, shut down,
then switch the `-device ide-hd`/`-device e1000` lines to
`-device virtio-blk-pci`/`-device virtio-net-pci`. Not needed to get a
working, usable VM — purely a later speed optimization.
