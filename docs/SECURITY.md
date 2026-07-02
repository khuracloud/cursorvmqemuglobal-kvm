# Security Model — cursorvmqemuglobal

This toolkit implements **defense in depth** for KVM hosts. It does not guarantee VM escape is impossible, but raises the bar substantially.

## Host layers

### Nested virtualization disabled

- `/etc/modprobe.d/kvm-no-nested.conf` sets `nested=0`
- KVM modules reloaded after install (AMD requires module reload)
- Guests cannot obtain `/dev/kvm`

### libvirt hardening

- TCP and TLS listeners disabled
- Polkit authentication on Unix sockets
- Audit logging enabled
- Connection limits

### QEMU emulator hardening

- AppArmor confinement **required** for all domains
- Emulator capabilities cleared
- Seccomp sandbox enabled
- SPICE/VNC bound to `127.0.0.1`
- Process and file descriptor limits

### Network isolation (libvirt hook)

On `virbr0` start, iptables rules:

- Allow guest → gateway DNS/DHCP only (UDP 53, 67, 68)
- Drop guest → gateway TCP/UDP/ICMP
- Drop guest → cloud metadata (`169.254.169.254`)
- Drop guest → localhost (`127.0.0.0/8`)
- Drop guest → host physical interface IPs

### QEMU domain hook

Blocks VM start if XML contains:

- Host device passthrough (`hostdev`)
- Host filesystem shares (`filesystem`, 9p, virtiofs)
- USB redirection
- Graphics listening on `0.0.0.0`

### Host sysctl

- `kernel.dmesg_restrict`
- `kernel.kptr_restrict`
- `kernel.unprivileged_bpf_disabled`
- Reverse-path filtering and martian logging

### Polkit

Only users in the `libvirt` group (and root) can manage VMs without admin prompt.

## Per-VM security (virt-install-secure)

- CPU: `host-passthrough` with `disable=svm,disable=vmx` (virt-install 4.x syntax)
- No live migration (`migratable=off`)
- Virtio network with `clean-traffic` nwfilter
- Windows: SATA disk; Linux: virtio disk
- TPM 2.0 emulator, watchdog, panic device
- Hyper-V enlightenments + KVM hidden
- `--os-variant` always specified

## Threat model

**In scope**: untrusted or capable software inside a guest trying to reach the host or escape the hypervisor.

**Out of scope**: physical access, host OS compromise, misconfiguration you add later (USB passthrough, folder shares), zero-day hypervisor bugs.

## Verification

```bash
sudo qemu-host-security-verify.sh   # on host
guest-security-audit.sh             # inside each guest
```

## Recommendations

1. Always create VMs with `virt-install-secure` / `virt-install-secure-windows` or the wizard
2. Do not add host folder mounts or USB passthrough
3. Keep host and guests patched
4. For maximum isolation, use a dedicated physical machine or isolated VLAN
