#!/usr/bin/env bash
# cursorvmqemuglobal — portable secure KVM/libvirt toolkit for Ubuntu LTS
#
# Usage:
#   sudo ./install.sh              # host hardening + install tools
#   sudo ./install.sh --purge-first
#   ./install.sh --dry-run
#   ./install.sh create-vm         # interactive VM wizard
#   sudo ./install.sh --wizard
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CURSORVMQEMU_ROOT="${SCRIPT_DIR}"

# shellcheck source=lib/common.sh
source "${CURSORVMQEMU_ROOT}/lib/common.sh"

DRY_RUN=0
PURGE_FIRST=0
MODE="install"
OFFER_WIZARD=1

usage() {
  cat <<'EOF'
cursorvmqemuglobal — secure KVM/libvirt toolkit for Ubuntu 22.04 / 24.04 / 26.04 LTS

Commands:
  (default)         Install hardened host stack (requires sudo)
  create-vm         Interactive VM creation wizard
  --wizard          Alias for create-vm

Options:
  --dry-run         Show actions without applying changes
  --purge-first     Remove existing qemu/libvirt packages before install
  --no-wizard       Skip post-install wizard prompt
  --help            Show this help

Examples:
  git clone https://github.com/khuracloud/cursorvmqemuglobal.git
  cd cursorvmqemuglobal
  chmod +x install.sh

  ./install.sh --dry-run
  sudo ./install.sh
  ./install.sh create-vm

Config:
  System defaults:  /etc/cursorvmqemu/defaults.env
  User overrides:   ~/.config/cursorvmqemu/config.env

Installed tools (/usr/local/bin/):
  virt-install-secure, virt-install-secure-windows
  qemu-host-security-verify.sh, guest-security-audit.sh
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --purge-first) PURGE_FIRST=1 ;;
    --no-wizard) OFFER_WIZARD=0 ;;
    --wizard|create-vm) MODE="wizard" ;;
    --help|-h) usage; exit 0 ;;
    --*) die "Unknown option: ${arg} (try --help)" ;;
    create-vm) MODE="wizard" ;;
  esac
done

export DRY_RUN PURGE_FIRST

case "${MODE}" in
  install)
    # shellcheck source=lib/install-host.sh
    source "${CURSORVMQEMU_ROOT}/lib/install-host.sh"
    run_host_install

    if (( ! DRY_RUN && OFFER_WIZARD )) && [[ -t 0 ]]; then
      echo ""
      if prompt_yes_no "Launch VM creation wizard now?" n; then
        # shellcheck source=lib/create-vm.sh
        source "${CURSORVMQEMU_ROOT}/lib/create-vm.sh"
        run_create_vm_wizard
      fi
    fi
    ;;
  wizard)
    # shellcheck source=lib/create-vm.sh
    source "${CURSORVMQEMU_ROOT}/lib/create-vm.sh"
    run_create_vm_wizard "$@"
    ;;
esac

exit 0
