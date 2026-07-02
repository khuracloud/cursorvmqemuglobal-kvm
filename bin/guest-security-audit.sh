#!/usr/bin/env bash
# Run inside a guest to sanity-check isolation posture.
set -u
pass=0; warn=0; crit=0
ok()   { echo "[PASS] $*"; pass=$((pass+1)); }
warn() { echo "[WARN] $*"; warn=$((warn+1)); }
crit() { echo "[CRIT] $*"; crit=$((crit+1)); }
echo "=== Guest security audit ==="
[[ -c /dev/kvm ]] && crit "/dev/kvm present in guest (nested virt?)" || ok "/dev/kvm absent"
grep -qE 'vmx|svm' /proc/cpuinfo 2>/dev/null && warn "vmx/svm flags visible (may be hidden)" || ok "no visible vmx/svm flags"
mount | grep -q '9p\|virtiofs' && crit "host-guest mount (9p/virtiofs) detected" || ok "no 9p/virtiofs shares"
systemctl is-active --quiet qemu-guest-agent 2>/dev/null && warn "qemu-guest-agent active" || ok "qemu-guest-agent inactive"
echo "PASS=$pass WARN=$warn CRIT=$crit"
(( crit == 0 )) || exit 2
exit 0
