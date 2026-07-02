# Setup Guide — cursorvmqemuglobal

## 1. Prerequisites

1. **Debian 11/12/13** or **Ubuntu LTS** (22.04, 24.04, or 26.04) on bare metal or a cloud instance with nested virt disabled.
2. **BIOS**: enable AMD-V (SVM) or Intel VT-x.
3. **Hardware check** (after first boot):

   ```bash
   sudo apt install -y cpu-checker
   kvm-ok
   ls -l /dev/kvm
   ```

## 2. Download

```bash
git clone https://github.com/khuracloud/cursorvmqemuglobal.git
cd cursorvmqemuglobal
chmod +x install.sh bin/*
```

## 3. Dry run (recommended)

```bash
./install.sh --dry-run
```

Shows packages and config files without applying changes. No root required.

## 4. Install

### Fresh system or upgrade in place

```bash
sudo ./install.sh
```

After install, the script offers to launch the VM creation wizard.

### Full reinstall (purges existing qemu/libvirt packages)

```bash
sudo ./install.sh --purge-first
```

## 5. Post-install

```bash
# Verify host hardening
sudo qemu-host-security-verify.sh

# Expected: PASS on all critical checks, 0 CRIT
# If nested KVM shows CRIT on AMD, reboot once:
sudo reboot
```

Log out and log back in so your user is in the `kvm` and `libvirt` groups.

## 6. Create virtual machines

### Interactive wizard (recommended)

```bash
./install.sh create-vm
```

Prompts for OS type, VM name, memory, vCPUs, disk size, and ISO path. Opens virt-viewer or virt-manager when done.

### Manual

```bash
sudo virt-install-secure --name my-vm --memory 8192 --vcpus 4 \
  --disk pool=default,size=40,format=qcow2 \
  --cdrom ~/Downloads/ubuntu-24.04.4-desktop-amd64.iso
```

## 7. Manage VMs

```bash
virt-manager          # GUI
virt-viewer -c qemu:///system MY-VM
virsh list --all      # CLI
```

SPICE display listens on **127.0.0.1 only** — use virt-manager or virt-viewer on the host.

## 8. Per-system configuration

System defaults: `/etc/cursorvmqemu/defaults.env`  
User overrides: `~/.config/cursorvmqemu/config.env`

The wizard auto-detects the libvirt default storage pool via `virsh pool-dumpxml default` and saves `DEFAULT_POOL` to your user config.

## 9. Troubleshooting

| Problem | Fix |
|---------|-----|
| `kvm_amd nested=1` CRIT | `sudo reboot` (modprobe config applies at boot) |
| `libvirt daemon inactive` WARN | Check `systemctl status libvirtd.socket` — socket activation is OK |
| libvirtd hung | See recovery steps printed by `qemu-host-security-verify.sh` or below |
| VM won't start: AppArmor | `sudo systemctl reload apparmor` |
| VM blocked by qemu hook | Remove hostdev / 9p shares / open graphics from VM XML |
| Permission denied on ISO | Use full path or `~/` (expanded for sudo user) |
| Wrong disk path | Use `pool=default` in `--disk` spec; pool path is auto-detected |

### libvirtd hang recovery

```bash
sudo systemctl stop libvirtd libvirtd.socket virtqemud virtqemud.socket
sudo systemctl reset-failed libvirtd virtqemud 2>/dev/null || true
sudo systemctl start virtlogd virtlogd.socket virtlockd virtlockd.socket
sudo systemctl start virtnetworkd virtnetworkd.socket
sudo systemctl start libvirtd.socket libvirtd virtqemud.socket virtqemud
virsh -c qemu:///system list --all
```

## 10. Uninstall

```bash
sudo ./install.sh --purge-first
sudo rm -rf /etc/cursorvmqemu
sudo rm -f /etc/modprobe.d/kvm-no-nested.conf
sudo rm -f /etc/sysctl.d/99-qemu-host-hardening.conf
sudo rm -f /etc/polkit-1/rules.d/50-libvirt-libvirt-group.rules
```

User config at `~/.config/cursorvmqemu/` is preserved unless you remove it manually.
