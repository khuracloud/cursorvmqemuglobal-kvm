#!/usr/bin/env bash
set -u
pass=0; warn=0; crit=0
ok()   { echo "[PASS] $*"; pass=$((pass+1)); }
warn() { echo "[WARN] $*"; warn=$((warn+1)); }
crit() { echo "[CRIT] $*"; crit=$((crit+1)); }
echo "=== KVM host security verification ==="
[[ -c /dev/kvm ]] && ok "/dev/kvm present" || crit "/dev/kvm missing"
for param in /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested; do
  [[ -f "$param" ]] || continue
  val=$(cat "$param")
  if [[ "$param" == *kvm_intel* ]]; then
    [[ "$val" == "N" || "$val" == "0" ]] && ok "kvm_intel nested off ($val)" || crit "kvm_intel nested=$val"
  else
    [[ "$val" == "0" || "$val" == "N" ]] && ok "kvm_amd nested off ($val)" || crit "kvm_amd nested=$val"
  fi
done
grep -q 'listen_tcp = 0' /etc/libvirt/libvirtd.conf.d/99-hardening.conf 2>/dev/null \
  && ok "libvirt TCP off" || warn "libvirtd hardening missing"
grep -q 'security_require_confined = 1' /etc/libvirt/qemu.conf.d/99-hardening.conf 2>/dev/null \
  && ok "AppArmor required" || warn "qemu.conf AppArmor missing"
grep -q 'seccomp_sandbox = 1' /etc/libvirt/qemu.conf.d/99-hardening.conf 2>/dev/null \
  && ok "QEMU seccomp on" || warn "qemu.conf seccomp missing"
[[ -x /etc/libvirt/hooks/network ]] && ok "network hook installed" || warn "network hook missing"
[[ -x /etc/libvirt/hooks/qemu ]] && ok "qemu hook installed" || warn "qemu hook missing"
[[ -f /etc/sysctl.d/99-qemu-host-hardening.conf ]] && ok "host sysctl hardening" || warn "sysctl hardening missing"
[[ -f /etc/polkit-1/rules.d/50-libvirt-libvirt-group.rules ]] && ok "polkit libvirt rule" || warn "polkit rule missing"
if systemctl is-active --quiet virtqemud 2>/dev/null \
  || systemctl is-active --quiet libvirtd 2>/dev/null \
  || systemctl is-active --quiet virtqemud.socket 2>/dev/null \
  || systemctl is-active --quiet libvirtd.socket 2>/dev/null; then
  ok "libvirt active (daemon or socket)"
else
  warn "libvirt daemon inactive"
fi
echo "PASS=$pass WARN=$warn CRIT=$crit"
(( crit == 0 )) || exit 2
exit 0
