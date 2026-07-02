#!/usr/bin/env bash
# Interactive VM creation wizard for cursorvmqemuglobal
set -Eeuo pipefail

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

WIZARD_DRY_RUN=0

wizard_usage() {
  cat <<'EOF'
Interactive VM creation:
  ./install.sh create-vm
  sudo ./install.sh --wizard
  ./install.sh create-vm --dry-run

Options:
  --dry-run    Show virt-install command without creating VM
EOF
}

pick_iso() {
  local iso="" search_dirs candidates count i choice
  load_config

  # Expand ~ in ISO_SEARCH_DIRS
  search_dirs="$(echo "${ISO_SEARCH_DIRS:-~/Downloads:~/ISOs}" | tr ':' '\n' | while read -r d; do expand_tilde "$d"; done | paste -sd: -)"

  if [[ -n "${LAST_ISO_PATH:-}" ]]; then
    local last_expanded
    last_expanded="$(expand_tilde "${LAST_ISO_PATH}")"
    if [[ -f "${last_expanded}" ]]; then
      if prompt_yes_no "Use last ISO (${LAST_ISO_PATH})?" y; then
        echo "${last_expanded}"
        return 0
      fi
    fi
  fi

  mapfile -t candidates < <(find_isos_in_dirs "${search_dirs}")
  count="${#candidates[@]}"

  if (( count > 0 )); then
    echo "" >&2
    echo "ISO files found in search dirs:" >&2
    for i in "${!candidates[@]}"; do
      printf "  %2d) %s\n" "$((i + 1))" "${candidates[$i]}" >&2
    done
    echo "" >&2
    read -r -p "Enter number, path, or press Enter to type path: " choice
    if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
      iso="${candidates[$((choice - 1))]}"
    elif [[ -n "${choice}" ]]; then
      iso="$(expand_tilde "${choice}")"
    fi
  fi

  if [[ -z "${iso}" ]]; then
    read -r -p "ISO path (supports ~): " iso
    iso="$(expand_tilde "${iso}")"
  fi

  if [[ ! -f "${iso}" ]]; then
    die "ISO not found: ${iso}"
  fi
  realpath "${iso}"
}

open_viewer() {
  local vm_name="$1" viewer="${PREFER_VIEWER:-ask}"

  if [[ "${viewer}" == "ask" ]]; then
    echo ""
    echo "Open viewer:"
    echo "  1) virt-viewer (console only)"
    echo "  2) virt-manager (full GUI)"
    echo "  3) none"
    read -r -p "Choice [1]: " choice
    case "${choice:-1}" in
      2) viewer="virt-manager" ;;
      3) return 0 ;;
      *) viewer="virt-viewer" ;;
    esac
  fi

  case "${viewer}" in
    virt-viewer)
      if command -v virt-viewer >/dev/null 2>&1; then
        log "Opening virt-viewer for ${vm_name}"
        nohup virt-viewer -c qemu:///system "${vm_name}" >/dev/null 2>&1 &
      else
        warn "virt-viewer not installed"
      fi
      ;;
    virt-manager)
      if command -v virt-manager >/dev/null 2>&1; then
        log "Opening virt-manager"
        nohup virt-manager >/dev/null 2>&1 &
      else
        warn "virt-manager not installed"
      fi
      ;;
  esac
}

run_create_vm_wizard() {
  for arg in "$@"; do
    case "$arg" in
      --dry-run) WIZARD_DRY_RUN=1 ;;
      --help|-h) wizard_usage; return 0 ;;
      --wizard) ;;
      create-vm) ;;
      *) die "Unknown option: ${arg}" ;;
    esac
  done

  load_config

  local pool_info pool_name pool_path profile vm_name memory vcpus disk_gb disk_spec
  local iso_path installer

  pool_info="$(detect_default_pool)"
  pool_name="${DEFAULT_POOL:-$(echo "${pool_info}" | cut -d'|' -f1)}"
  pool_path="$(echo "${pool_info}" | cut -d'|' -f2)"

  log "VM creation wizard"
  echo "Detected storage pool: ${pool_name} (${pool_path})"
  save_user_config_kv "DEFAULT_POOL" "${pool_name}"

  echo ""
  echo "Guest OS type:"
  echo "  1) Ubuntu / Linux (virtio disk)"
  echo "  2) Windows (SATA disk, virtio network)"
  read -r -p "Choice [1]: " profile_choice
  case "${profile_choice:-1}" in
    2) profile="windows" ;;
    *) profile="linux" ;;
  esac

  vm_name="$(prompt_default "VM name" "secure-vm-$(date +%Y%m%d)")"
  memory="$(prompt_default "Memory (MB)" "${DEFAULT_MEMORY_MB:-8192}")"
  vcpus="$(prompt_default "vCPUs" "${DEFAULT_VCPUS:-4}")"

  if [[ "${profile}" == "windows" ]]; then
    disk_gb="$(prompt_default "Disk size (GB)" "${DEFAULT_DISK_GB_WINDOWS:-60}")"
  else
    disk_gb="$(prompt_default "Disk size (GB)" "${DEFAULT_DISK_GB:-40}")"
  fi

  iso_path="$(pick_iso)"
  save_user_config_kv "LAST_ISO_PATH" "${iso_path}"

  disk_spec="pool=${pool_name},size=${disk_gb},format=qcow2"

  if [[ "${profile}" == "windows" ]]; then
    installer="virt-install-secure-windows"
  else
    installer="virt-install-secure"
  fi

  # Prefer installed copy, fall back to repo bin/
  if [[ -x /usr/local/bin/${installer} ]]; then
    installer="/usr/local/bin/${installer}"
  elif [[ -x "${CURSORVMQEMU_ROOT}/bin/${installer}" ]]; then
    installer="${CURSORVMQEMU_ROOT}/bin/${installer}"
  else
    die "Could not find ${installer}. Run sudo ./install.sh first."
  fi

  log "Creating VM: ${vm_name}"
  echo ""
  echo "Command:"
  echo "  sudo ${installer} \\"
  echo "    --name ${vm_name} \\"
  echo "    --memory ${memory} \\"
  echo "    --vcpus ${vcpus} \\"
  echo "    --disk ${disk_spec} \\"
  echo "    --cdrom ${iso_path}"
  echo ""

  if (( WIZARD_DRY_RUN )); then
    "${installer}" \
      --name "${vm_name}" \
      --memory "${memory}" \
      --vcpus "${vcpus}" \
      --disk "${disk_spec}" \
      --cdrom "${iso_path}" \
      --dry-run
    log "Dry-run complete (no VM created)"
    return 0
  fi

  if [[ $EUID -ne 0 ]]; then
    sudo "${installer}" \
      --name "${vm_name}" \
      --memory "${memory}" \
      --vcpus "${vcpus}" \
      --disk "${disk_spec}" \
      --cdrom "${iso_path}"
  else
    "${installer}" \
      --name "${vm_name}" \
      --memory "${memory}" \
      --vcpus "${vcpus}" \
      --disk "${disk_spec}" \
      --cdrom "${iso_path}"
  fi

  log "VM ${vm_name} created — starting viewer"
  sleep 2
  open_viewer "${vm_name}"

  cat <<EOF

[OK] VM "${vm_name}" is ready for OS installation.

Connect later:
  virt-viewer -c qemu:///system ${vm_name}
  virt-manager

Verify guest isolation (inside VM after install):
  guest-security-audit.sh

EOF
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  run_create_vm_wizard "$@"
fi
