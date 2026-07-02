# cursorvmqemuglobal

Portable, high-security **QEMU/KVM** toolkit for **Ubuntu 22.04 / 24.04 / 26.04 LTS**. Works on any fresh Ubuntu machine — no hardcoded user paths.

One repo replaces the separate `install-qemu-secure`, `virt-install-secure`, and `qemu-guest-security-audit` projects.

## Quick start

```bash
git clone https://github.com/khuracloud/cursorvmqemuglobal.git
cd cursorvmqemuglobal
chmod +x install.sh

# Preview (no root required)
./install.sh --dry-run

# Install hardened host stack
sudo ./install.sh

# Verify host
sudo qemu-host-security-verify.sh

# Create a VM (interactive wizard)
./install.sh create-vm
```

Log out and back in after install so `kvm` / `libvirt` group membership applies.

## What you get

| Component | Location |
|-----------|----------|
| Main installer + wizard | `./install.sh` |
| Secure VM helper | `/usr/local/bin/virt-install-secure` |
| Windows helper | `/usr/local/bin/virt-install-secure-windows` |
| Host verifier | `/usr/local/bin/qemu-host-security-verify.sh` |
| Guest auditor | `/usr/local/bin/guest-security-audit.sh` |
| System defaults | `/etc/cursorvmqemu/defaults.env` |
| User config | `~/.config/cursorvmqemu/config.env` |
| Secure VM template | `/usr/share/libvirt/secure-vm-baseline.xml` |

## Commands

```bash
sudo ./install.sh                  # install / upgrade host stack
sudo ./install.sh --purge-first    # purge old qemu/libvirt first
./install.sh --dry-run             # simulate only
./install.sh create-vm             # interactive VM wizard
sudo ./install.sh --wizard         # same wizard (with sudo for virt-install)
```

## Create VMs manually

```bash
# Ubuntu (virtio disk)
sudo virt-install-secure --name my-vm --memory 8192 --vcpus 4 \
  --disk pool=default,size=40,format=qcow2 \
  --cdrom ~/Downloads/ubuntu-24.04.4-desktop-amd64.iso

# Windows 10 (SATA disk, virtio network)
sudo virt-install-secure-windows --name win10 --memory 8192 --vcpus 4 \
  --disk pool=default,size=60,format=qcow2 \
  --cdrom ~/Downloads/Win10_22H2_English_x64v1.iso
```

## Configuration

User overrides in `~/.config/cursorvmqemu/config.env`:

```bash
DEFAULT_POOL="default"                          # auto-detected on first wizard run
ISO_SEARCH_DIRS="~/Downloads:~/ISOs"
LAST_ISO_PATH=""                                # set by wizard
PREFER_VIEWER="ask"                             # ask | virt-viewer | virt-manager
DEFAULT_MEMORY_MB="8192"
DEFAULT_VCPUS="4"
DEFAULT_DISK_GB="40"
DEFAULT_DISK_GB_WINDOWS="60"
```

## Fixes included (virt-install 4.x)

- CPU: `disable=svm,disable=vmx` (not `feature.svm`)
- `--os-variant` always set
- Features use dot notation: `hyperv.relaxed.state=on`
- `--cdrom` primary; `--cdlocation` supported as alias
- `~/` expanded for sudo user via `SUDO_USER` home
- Disk uses `pool=default` (or detected pool), not hardcoded `/var/lib/libvirt/images`
- Windows: SATA disk; Ubuntu: virtio disk
- AMD nested KVM module reload after install

## Documentation

- [Setup guide](docs/SETUP.md)
- [Security model](docs/SECURITY.md)

## Requirements

- Ubuntu 22.04 / 24.04 / 26.04 LTS (64-bit)
- CPU with AMD-V or Intel VT-x in BIOS
- Bare metal or cloud instance with KVM (not nested inside another VM)
- `sudo` access

## License

MIT — see [LICENSE](LICENSE).
