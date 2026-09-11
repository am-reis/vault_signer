# Windows VM on Debian via QEMU (CLI), OVMF, and swtpm

A Windows 11 VM on a headless Debian server, driven entirely from the
command line, with UEFI + Secure Boot + a software TPM 2.0 (so
Windows Hello and the WebAuthn platform authenticator work — spec
§6.2's actual target), accessed over SSH + VNC from your Mac.

**Now actually run on the real target server**, up through VM-disk and
TPM provisioning (not yet through an actual Windows install — that's
an interactive, GUI-driven step over VNC left for a human). Real
findings from doing this, not assumed:

- The server runs **Debian 11 (bullseye)**, now `oldoldstable`/EOL.
  **`swtpm` and its dependency `libtpms` were never packaged for
  bullseye at all** — they only entered the Debian archive starting
  with bookworm (Debian 12); `apt install swtpm` fails with "Unable to
  locate package" on this box, full stop, not a mirror hiccup
  (confirmed via `packages.debian.org`'s own per-suite package search).
  Built both from source instead — see the new §0a below. This also
  means Debian 12+ can just `apt install swtpm swtpm-tools` normally;
  only bullseye needs this workaround.
- Separately, bullseye's own `bullseye-security` repo is serving stale
  metadata on this box (`Release file ... is expired`) and 404s on
  several real `.deb` files (`libssl-dev`, `libgnutls-dane0`,
  `libgnutls28-dev`) that its own index still lists — consistent with
  bullseye's regular security-archive support having ended. Worked
  around by building `swtpm` with `--without-gnutls` (gnutls is only
  used for `swtpm_cert`'s EK-certificate feature, not needed for local
  Windows Hello/TPM use) so the build never needs those broken
  packages; `libssl-dev` was already present at a sufficient version
  and needed no reinstall.
- Disk-space-driven deviation from the paths below: this server's `/`
  (SSD) is tight, so the VM's actual files live on a separate spinning
  disk at `/home/blackshark/backup/windows-vm` instead of
  `/srv/vms/windows`. Substitute that for every `$VMDIR` below if
  working on this exact box — the three ready-to-run scripts already
  there (`start-tpm.sh`, `install.sh`, `run.sh`) already point at it.
  `qemu-system-x86_64`, `qemu-utils`, `ovmf`, and `cpu-checker` were
  already installed on this box; `kvm-ok` (via `/usr/sbin/kvm-ok`,
  not on a normal user's `$PATH`) confirmed real KVM acceleration is
  available.

## 0a. Building swtpm from source (bullseye only)

Skip this whole section on Debian 12+ — just `apt install swtpm
swtpm-tools` there. On bullseye, `swtpm` isn't in the archive at any
version, so build `libtpms` (the TPM emulation library `swtpm` links
against) and then `swtpm` itself from their upstream source releases:

```bash
sudo apt install -y build-essential autoconf automake libtool pkg-config \
    libtasn1-6-dev libjson-glib-dev libseccomp-dev expect

curl -sL https://github.com/stefanberger/libtpms/archive/refs/tags/v0.9.6.tar.gz -o libtpms.tar.gz
curl -sL https://github.com/stefanberger/swtpm/archive/refs/tags/v0.8.1.tar.gz -o swtpm.tar.gz
tar xzf libtpms.tar.gz && tar xzf swtpm.tar.gz

cd libtpms-0.9.6
./autogen.sh --with-openssl --prefix=/usr/local
make -j"$(nproc)"
sudo make install
sudo ldconfig
cd ..

cd swtpm-0.8.1
PKG_CONFIG_PATH=/usr/local/lib/pkgconfig ./autogen.sh --prefix=/usr/local --without-gnutls --without-seccomp
make -j"$(nproc)"
sudo make install
sudo ldconfig
```

(`--without-seccomp` just means the optional seccomp sandboxing profile
isn't built; unrelated to whether the emulated TPM itself works.
`libssl-dev` is a hard requirement for `libtpms` — install it too if
your box doesn't already have it, via plain `apt install libssl-dev`
on a box where that package isn't affected by the stale-repo issue
above.) This installs real, working `swtpm`/`swtpm_setup`/`swtpm_bios`/
`swtpm_ioctl`/`swtpm_localca` binaries to `/usr/local/bin` — confirmed
via `swtpm --version` reporting `TPM emulator version 0.8.1`.

**Caution — run `autogen.sh`/`configure` from inside each source
directory** (`cd libtpms-0.9.6 && ./autogen.sh ...`, not
`./libtpms-0.9.6/autogen.sh ...` from elsewhere): some of these
`autogen.sh`/`configure` scripts write their generated `Makefile` and
friends into the *current working directory*, not the script's own
directory. Running it via a path from an unrelated directory (e.g.
this repo's checkout) silently drops a full build tree into whatever
directory you happened to be in.

## 0. One-time host prerequisites

On the Debian server:

```bash
sudo apt update
sudo apt install qemu-system-x86 qemu-utils ovmf cpu-checker
```

(Add `swtpm swtpm-tools` to that line too **on Debian 12 or newer**;
on bullseye, see §0a above instead — those packages don't exist there.)

Confirm hardware virtualization is actually usable — without this,
QEMU falls back to full software emulation and everything below will
be painfully slow:

```bash
kvm-ok
```

If that reports KVM acceleration can be used, you're set. If not,
stop here and fix that first (BIOS virtualization setting, or — if
this Debian box is itself a VM — nested virtualization needs to be
enabled on its host). (On this server, `kvm-ok` itself is at
`/usr/sbin/kvm-ok`, which isn't on a normal user's `$PATH` by default —
call it by that full path if `kvm-ok` alone says "command not found.")

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
actually printed** if it differs. On this server both exact files
exist at those paths, confirmed directly.

## 1. Get a Windows 11 ISO

Download from Microsoft directly:
<https://www.microsoft.com/software-download/windows11> (the "Download
Windows 11 Disk Image (ISO)" option). Copy it to the Debian server,
e.g. `$VMDIR/Win11.iso` (on this server, `$VMDIR` is
`/home/blackshark/backup/windows-vm` — see the deviation noted above;
substitute `/srv/vms/windows` if following this guide fresh elsewhere).
**Not yet done on this server** — this is the one manual step left
before `install.sh` (below) can boot the installer.

## 2. Create the VM's disk and per-VM UEFI vars

**Already done on this server** — `disk.qcow2` (100G, sparse) and
`OVMF_VARS.fd` both exist under `/home/blackshark/backup/windows-vm`,
owned by `blackshark` (that directory started out `root`-owned; fixed
with a one-off `chown` since this account has no write access there
otherwise). To redo this elsewhere:

```bash
VMDIR=/srv/vms/windows   # or wherever you have room — see the disk-space note above
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
connects to as `tpm-tis` (the standard PC TPM device Windows expects).
On this server, `$VMDIR/start-tpm.sh` already does this (built from
source per §0a above, since bullseye has no `swtpm` package) — just
run it:

```bash
/home/blackshark/backup/windows-vm/start-tpm.sh
```

Elsewhere, the equivalent by hand:

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

On this server, once the ISO is in place at `$VMDIR/Win11.iso`, just
run `$VMDIR/install.sh` (checks the ISO exists first). Elsewhere, or to
see exactly what it runs:

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
    -drive file="$VMDIR/Win11.iso",media=cdrom \
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
`-drive ...Win11.iso,media=cdrom` line — same command otherwise.
Already created on this server as `$VMDIR/run.sh` (executable, ready to
use once Windows is actually installed); to reproduce elsewhere:

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
