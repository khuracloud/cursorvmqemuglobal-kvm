#!/usr/bin/env bash
# Host hardening and package install for cursorvmqemuglobal
set -Eeuo pipefail

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

PURGE_FIRST="${PURGE_FIRST:-0}"
NEEDS_REBOOT_FOR_NESTED=0
VERIFY_OK=1

LIBVIRT_NETWORK_HOOK="/etc/libvirt/hooks/network"
LIBVIRT_QEMU_HOOK="/etc/libvirt/hooks/qemu"
SECURE_TEMPLATE="/usr/share/libvirt/secure-vm-baseline.xml"
POLKIT_RULE="/etc/polkit-1/rules.d/50-libvirt-libvirt-group.rules"
SYSCTL_CONF="/etc/sysctl.d/99-qemu-host-hardening.conf"

install_host_usage() {
  cat <<'EOF'
Host install (requires root):
  sudo ./install.sh
  sudo ./install.sh --purge-first
  ./install.sh --dry-run
EOF
}

stop_libvirt_stack() {
  (( DRY_RUN )) && return 0
  log "Stopping libvirt/KVM stack"
  for svc in libvirtd libvirtd.socket libvirt-guests.service \
             virtqemud virtqemud.socket virtnetworkd virtnetworkd.socket \
             virtlogd virtlogd.socket virtlockd virtlockd.socket \
             virtguestsd virtguestsd.socket virtproxyd virtproxyd.socket; do
    systemctl stop "${svc}" 2>/dev/null || true
  done
}

start_libvirt_stack() {
  (( DRY_RUN )) && return 0
  log "Enabling core libvirt services"
  for svc in virtlogd virtlogd.socket virtlockd virtlockd.socket \
             virtnetworkd virtnetworkd.socket \
             libvirtd.socket libvirtd \
             virtqemud virtqemud.socket; do
    systemctl enable "${svc}" 2>/dev/null || true
    systemctl start "${svc}" 2>/dev/null || true
  done
}

unload_kvm_modules() {
  if lsmod | grep -q '^kvm_amd '; then
    modprobe -r kvm_amd
  elif lsmod | grep -q '^kvm_intel '; then
    modprobe -r kvm_intel
  fi
  modprobe -r kvm 2>/dev/null || true
}

load_kvm_modules_nested_off() {
  modprobe kvm
  if is_amd_cpu; then
    modprobe kvm_amd nested=0
  else
    modprobe kvm_intel nested=0
  fi
}

disable_nested_kvm() {
  log "Disabling nested KVM (guests must not get /dev/kvm)"
  write_file /etc/modprobe.d/kvm-no-nested.conf <<'EOF'
# Guests must not get hardware virt extensions (blocks /dev/kvm inside VMs).
options kvm_intel nested=0
options kvm_amd nested=0
EOF

  if (( DRY_RUN )); then
    echo "  [dry-run] nested KVM off via modprobe.d + module reload"
    return 0
  fi

  local param
  for param in /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested; do
    [[ -w "$param" ]] || continue
    echo 0 >"$param" 2>/dev/null || true
  done

  nested_still_on || { log_nested_state; return 0; }

  mapfile -t running < <(virsh -c qemu:///system list --name 2>/dev/null | sed '/^$/d' || true)
  if ((${#running[@]})); then
    warn "Running VMs (${running[*]}) — nested stays active until shutdown or reboot"
    NEEDS_REBOOT_FOR_NESTED=1
    return 0
  fi

  log "Reloading KVM modules (nested=0) — required on AMD"
  stop_libvirt_stack
  if ! unload_kvm_modules; then
    warn "Could not unload KVM modules — nested applies on next reboot"
    NEEDS_REBOOT_FOR_NESTED=1
    return 0
  fi
  load_kvm_modules_nested_off

  if nested_still_on; then
    warn "Nested KVM still active after reload — reboot to apply modprobe.d"
    NEEDS_REBOOT_FOR_NESTED=1
  fi
  log_nested_state
}

purge_existing_stack() {
  (( PURGE_FIRST )) || return 0
  log "Mode --purge-first: removing existing QEMU/libvirt stack"

  if command -v virsh >/dev/null 2>&1; then
    mapfile -t running < <(virsh -c qemu:///system list --name 2>/dev/null | sed '/^$/d' || true)
    for vm in "${running[@]:-}"; do
      [[ -n "${vm}" ]] || continue
      warn "Shutting down VM: ${vm}"
      virsh -c qemu:///system destroy "${vm}" >/dev/null 2>&1 || true
    done
  fi

  stop_libvirt_stack

  if (( DRY_RUN )); then
    echo "  [dry-run] apt-get purge qemu-* libvirt-* virt-manager virtinst ..."
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  mapfile -t purge_pkgs < <(
    dpkg-query -W -f='${Package}\n' \
      'qemu-*' 'libvirt-*' 'virt-manager' 'virtinst' 'ovmf' 'swtpm' 'swtpm-tools' \
      'ipxe-qemu' 'ipxe-qemu-*' 'python3-libvirt' 'gir1.2-libvirt-*' 2>/dev/null \
      | sort -u
  )
  if ((${#purge_pkgs[@]})); then
    apt-get purge -y "${purge_pkgs[@]}"
  fi
  apt-get autoremove -y
  apt-get autoclean -y

  rm -rf /etc/libvirt/libvirtd.conf.d /etc/libvirt/qemu.conf.d
  rm -f /etc/modprobe.d/kvm-no-nested.conf
  rm -f "${LIBVIRT_NETWORK_HOOK}" "${LIBVIRT_QEMU_HOOK}"
  rm -f "${SECURE_TEMPLATE}" "${POLKIT_RULE}" "${SYSCTL_CONF}"
  rm -rf "${CURSORVMQEMU_ETC}"
}

install_bin_scripts() {
  log "Installing scripts to /usr/local/bin/"
  local script dest
  for script in virt-install-secure virt-install-secure-windows \
                guest-security-audit.sh qemu-host-security-verify.sh; do
    dest="/usr/local/bin/${script}"
    install_file "${CURSORVMQEMU_ROOT}/bin/${script}" "${dest}" 755
  done
}

install_system_config() {
  log "Installing system defaults to ${CURSORVMQEMU_ETC}/"
  install_file "${CURSORVMQEMU_ROOT}/config/defaults.env" \
    "${CURSORVMQEMU_SYSTEM_DEFAULTS}" 644
}

install_host_configs() {
  local qemu_machine="$1"
  local pool_path
  pool_path="$(get_default_pool_path)"

  log "Host sysctl hardening"
  write_file "${SYSCTL_CONF}" <<'EOF'
# QEMU/KVM host hardening
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.unprivileged_bpf_disabled = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
EOF
  if (( ! DRY_RUN )); then
    sysctl --system >/dev/null 2>&1 || sysctl -p "${SYSCTL_CONF}" >/dev/null 2>&1 || true
  fi

  log "Polkit: libvirt group manages VMs"
  write_file "${POLKIT_RULE}" <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.libvirt.api") === 0) {
        if (subject.isInGroup("libvirt")) {
            return polkit.Result.YES;
        }
        if (subject.user === "root") {
            return polkit.Result.YES;
        }
        return polkit.Result.AUTH_ADMIN;
    }
});
EOF

  log "libvirtd hardening"
  write_file /etc/libvirt/libvirtd.conf.d/99-hardening.conf <<'EOF'
listen_tls = 0
listen_tcp = 0
tls_port = "-1"
tcp_port = "-1"
auth_unix_ro = "polkit"
auth_unix_rw = "polkit"
max_clients = 32
max_queued_clients = 16
log_level = 3
audit_level = 1
admin_min_workers = 1
admin_max_workers = 3
keepalive_interval = 5
keepalive_count = 5
EOF

  log "QEMU emulator hardening"
  write_file /etc/libvirt/qemu.conf.d/99-hardening.conf <<'EOF'
security_driver = "apparmor"
security_default_confined = 1
security_require_confined = 1
clear_emulator_capabilities = 1
user = "root"
group = "root"
dynamic_ownership = 1
remember_owner = 1
spice_listen = "127.0.0.1"
vnc_listen = "127.0.0.1"
vnc_auto_unix_socket = 1
stdio_handler = "logd"
seccomp_sandbox = 1
max_processes = 512
max_files = 8192
migrate_tls_x509_cert_dir = "/etc/pki/libvirt/private"
EOF

  log "Network hook: guest isolation from host bridge"
  write_file "${LIBVIRT_NETWORK_HOOK}" <<'HOOK'
#!/usr/bin/env bash
# Libvirt network hook — guest isolation from host bridge/gateway
set -euo pipefail
OP="${2:-}"

apply_isolation() {
  local br="${1:-virbr0}"
  local gw_ip
  gw_ip="$(ip -4 addr show dev "${br}" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)"
  [[ -n "${gw_ip}" ]] || return 0
  command -v iptables >/dev/null 2>&1 || return 0

  local -a rules=(
    "-i ${br} -d ${gw_ip} -p udp -m multiport --dports 53,67,68 -j ACCEPT"
    "-i ${br} -d ${gw_ip} -p icmp -j DROP"
    "-i ${br} -d ${gw_ip} -p tcp -j DROP"
    "-i ${br} -d ${gw_ip} -p udp -j DROP"
    "-i ${br} -d 169.254.169.254/32 -j DROP"
    "-i ${br} -d 127.0.0.0/8 -j DROP"
  )

  local spec pos=1
  for spec in "${rules[@]}"; do
    # shellcheck disable=SC2086
    iptables -C FORWARD ${spec} 2>/dev/null || iptables -I FORWARD ${pos} ${spec}
    pos=$((pos + 1))
  done

  local ip
  while read -r ip; do
    [[ -n "${ip}" && "${ip}" != "${gw_ip}" ]] || continue
    spec="-i ${br} -d ${ip}/32 -j DROP"
    # shellcheck disable=SC2086
    iptables -C FORWARD ${spec} 2>/dev/null || iptables -A FORWARD ${spec}
  done < <(ip -4 -o addr show scope global 2>/dev/null | awk '$2!="virbr0" && $2!="lo" {split($4,a,"/"); print a[1]}' | sort -u)
}

case "${OP}" in
  started) apply_isolation virbr0 ;;
esac
exit 0
HOOK
  chmod_file 755 "${LIBVIRT_NETWORK_HOOK}"

  log "QEMU hook: block passthrough and open displays"
  write_file "${LIBVIRT_QEMU_HOOK}" <<'QEMUHOOK'
#!/usr/bin/env bash
# Reject VM configs that weaken isolation (hostdev, host filesystem shares, open graphics)
set -euo pipefail
GUEST="${1:-}"
OP="${2:-}"
SUB="${3:-}"

[[ "${OP}" == "prepare" && "${SUB}" == "begin" ]] || exit 0
[[ -n "${GUEST}" ]] || exit 0

xml="$(virsh dumpxml "${GUEST}" 2>/dev/null || true)"
[[ -n "${xml}" ]] || exit 0

if grep -qE '<hostdev |<filesystem |<redirdev |<redirfilter' <<<"${xml}"; then
  echo "SECURITY: ${GUEST} — hostdev/filesystem/USB redirection blocked by policy" >&2
  exit 1
fi

if grep -qE "listen='0\\.0\\.0\\.0'|address='0\\.0\\.0\\.0'" <<<"${xml}"; then
  echo "SECURITY: ${GUEST} — graphics must listen on 127.0.0.1 only" >&2
  exit 1
fi

if grep -q "type='vnc'" <<<"${xml}" && ! grep -q "listen='127.0.0.1'" <<<"${xml}"; then
  echo "SECURITY: ${GUEST} — VNC must be localhost-only" >&2
  exit 1
fi

exit 0
QEMUHOOK
  chmod_file 755 "${LIBVIRT_QEMU_HOOK}"

  log "Secure VM baseline XML (machine=${qemu_machine}, pool path=${pool_path})"
  write_file "${SECURE_TEMPLATE}" <<XML
<!-- High-security VM baseline — edit REPLACE_ME fields -->
<domain type='kvm'>
  <name>REPLACE_ME</name>
  <memory unit='GiB'>8</memory>
  <currentMemory unit='GiB'>8</currentMemory>
  <vcpu placement='static'>4</vcpu>
  <os firmware='efi'>
    <type arch='x86_64' machine='${qemu_machine}'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <hyperv mode='custom'>
      <relaxed state='on'/>
      <vapic state='on'/>
      <spinlocks state='on' retries='8191'/>
      <vpindex state='on'/>
      <runtime state='on'/>
      <synic state='on'/>
      <stimer state='on'/>
      <frequencies state='on'/>
    </hyperv>
    <kvm>
      <hidden state='on'/>
    </kvm>
    <vmport state='off'/>
    <smm state='on'/>
  </features>
  <cpu mode='host-passthrough' check='none' migratable='off'>
    <feature policy='disable' name='vmx'/>
    <feature policy='disable' name='svm'/>
  </cpu>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
    <timer name='hypervclock' present='yes'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <pm>
    <suspend-to-mem enabled='no'/>
    <suspend-to-disk enabled='no'/>
  </pm>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='native' discard='unmap'/>
      <source file='${pool_path}/REPLACE_ME.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <controller type='usb' model='qemu-xhci'/>
    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
      <filterref filter='clean-traffic'/>
    </interface>
    <graphics type='spice' autoport='yes' listen='127.0.0.1'>
      <listen type='address' address='127.0.0.1'/>
    </graphics>
    <video>
      <model type='virtio' heads='1' primary='yes'/>
    </video>
    <memballoon model='virtio'/>
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
    </rng>
    <tpm model='tpm-crb'>
      <backend type='emulator' version='2.0'/>
    </tpm>
    <watchdog model='itco' action='reset'/>
    <panic model='hyperv'/>
    <channel type='spicevmc'>
      <target type='virtio' name='com.redhat.spice.0'/>
    </channel>
  </devices>
</domain>
XML
}

run_host_install() {
  local USER_NAME

  if (( DRY_RUN )); then
    log "DRY-RUN mode — no changes applied"
    [[ $EUID -eq 0 ]] || warn "Dry-run without root: some checks skipped"
  else
    [[ $EUID -eq 0 ]] || die "Run with sudo: sudo ./install.sh"
  fi

  USER_NAME="$(real_user)"
  (( DRY_RUN )) && [[ -z "${USER_NAME}" ]] && USER_NAME="${USER:-root}"
  [[ -n "${USER_NAME}" ]] || die "Could not detect real user"

  log "Checking Ubuntu"
  # shellcheck disable=SC1091
  source /etc/os-release || die "Missing /etc/os-release"
  [[ "${ID:-}" == "ubuntu" ]] || warn "Tested on Ubuntu; other distros may differ."
  echo "System: ${PRETTY_NAME:-unknown} (VERSION_ID=${VERSION_ID:-?})"

  case "${VERSION_ID:-}" in
    22.04|24.04|26.04) echo "Compatibility: supported LTS" ;;
    *) warn "VERSION_ID=${VERSION_ID:-?} not officially tested (22.04/24.04/26.04)" ;;
  esac

  if is_live_session; then
    warn "LIVE session detected — changes lost on reboot"
    [[ -c /dev/kvm ]] || warn "/dev/kvm not available"
  fi

  BASE_PKGS=(
    qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients
    virt-manager virtinst bridge-utils cpu-checker dnsmasq-base
    ovmf swtpm apparmor apparmor-utils iptables libguestfs-tools numactl
  )
  HWE_PKGS=()
  [[ "${VERSION_ID:-}" == "26.04" ]] && HWE_PKGS=(ubuntu-helper-virt-hwe)

  purge_existing_stack

  log "Updating package lists"
  run "export DEBIAN_FRONTEND=noninteractive; apt-get update -y"

  log "Installing packages"
  if (( DRY_RUN )); then
    echo "  [dry-run] apt-get install -s -y ${BASE_PKGS[*]} ${HWE_PKGS[*]:-}"
    DEBIAN_FRONTEND=noninteractive apt-get install -s -y "${BASE_PKGS[@]}" ${HWE_PKGS[@]+"${HWE_PKGS[@]}"} 2>&1 | tail -8 || true
  else
    apt-get install -y "${BASE_PKGS[@]}" ${HWE_PKGS[@]+"${HWE_PKGS[@]}"}
  fi

  if (( ! DRY_RUN )); then
    log "Checking KVM"
    command -v kvm-ok >/dev/null 2>&1 && kvm-ok || warn "kvm-ok reported issues"
    [[ -c /dev/kvm ]] || die "/dev/kvm does not exist"
  fi

  QEMU_MACHINE="$(detect_qemu_machine)"
  install_host_configs "${QEMU_MACHINE}"
  install_bin_scripts
  install_system_config
  disable_nested_kvm

  if (( ! DRY_RUN )); then
    log "Adding ${USER_NAME} to libvirt/kvm groups"
    usermod -aG libvirt "${USER_NAME}" || true
    usermod -aG kvm "${USER_NAME}" || true

    start_libvirt_stack

    log "Default network + isolation"
    if command -v virsh >/dev/null 2>&1; then
      virsh net-define /usr/share/libvirt/networks/default.xml >/dev/null 2>&1 || true
      virsh net-start default >/dev/null 2>&1 || true
      virsh net-autostart default >/dev/null 2>&1 || true
      [[ -x "${LIBVIRT_NETWORK_HOOK}" ]] && "${LIBVIRT_NETWORK_HOOK}" default started begin - || true
    fi

    systemctl reload apparmor 2>/dev/null || true
    systemctl restart polkit 2>/dev/null || true
  fi

  log "Final checks"
  if (( ! DRY_RUN )); then
    virsh -c qemu:///system list --all 2>/dev/null || true
    if /usr/local/bin/qemu-host-security-verify.sh; then
      VERIFY_OK=1
    else
      VERIFY_OK=0
      warn "Verification reported issues — see above"
      libvirtd_recovery_hint
    fi
  else
    echo "  [dry-run] skipping live virsh/verify"
    echo "  [dry-run] files that would be written:"
    echo "    ${SYSCTL_CONF}"
    echo "    ${POLKIT_RULE}"
    echo "    /etc/libvirt/libvirtd.conf.d/99-hardening.conf"
    echo "    /etc/libvirt/qemu.conf.d/99-hardening.conf"
    echo "    ${LIBVIRT_NETWORK_HOOK}"
    echo "    ${LIBVIRT_QEMU_HOOK}"
    echo "    ${SECURE_TEMPLATE}"
    echo "    ${CURSORVMQEMU_SYSTEM_DEFAULTS}"
    echo "    /usr/local/bin/{virt-install-secure,virt-install-secure-windows,guest-security-audit.sh,qemu-host-security-verify.sh}"
  fi

  local REBOOT_MSG="not required"
  (( NEEDS_REBOOT_FOR_NESTED )) && REBOOT_MSG="recommended (nested KVM)"

  cat <<EOF

[OK] Secure host installation complete.

System: ${PRETTY_NAME:-Ubuntu} ${VERSION_ID:-}
Reboot: ${REBOOT_MSG}

Verify host:
  sudo qemu-host-security-verify.sh

Audit inside each guest:
  guest-security-audit.sh

Create a VM (interactive wizard):
  ./install.sh create-vm
  sudo ./install.sh --wizard

Or use virt-install-secure directly:
  sudo virt-install-secure --name my-vm --memory 8192 --vcpus 4 \\
    --disk pool=default,size=40,format=qcow2 \\
    --cdrom ~/Downloads/ubuntu-24.04.4-desktop-amd64.iso

EOF

  (( DRY_RUN )) && echo "Re-run with sudo (no --dry-run) to apply."
  (( NEEDS_REBOOT_FOR_NESTED )) && echo "Reboot recommended: sudo reboot"
  (( VERIFY_OK )) || warn "Install finished but verification incomplete"

  return 0
}

# Allow sourcing or direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  run_host_install "$@"
fi
