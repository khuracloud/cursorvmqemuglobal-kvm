#!/usr/bin/env bash
# Shared utilities for cursorvmqemuglobal
# shellcheck disable=SC2034
set -Eeuo pipefail

# Resolve repo root from any sourced script
if [[ -z "${CURSORVMQEMU_ROOT:-}" ]]; then
  _common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CURSORVMQEMU_ROOT="$(cd "${_common_dir}/.." && pwd)"
fi

# Config locations (no hardcoded user paths)
CURSORVMQEMU_ETC="${CURSORVMQEMU_ETC:-/etc/cursorvmqemu}"
CURSORVMQEMU_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/cursorvmqemu"
CURSORVMQEMU_USER_CONFIG="${CURSORVMQEMU_CONFIG_DIR}/config.env"
CURSORVMQEMU_SYSTEM_DEFAULTS="${CURSORVMQEMU_ETC}/defaults.env"
CURSORVMQEMU_REPO_DEFAULTS="${CURSORVMQEMU_ROOT}/config/defaults.env"

DRY_RUN="${DRY_RUN:-0}"

log()  { echo -e "\n[+] $*"; }
warn() { echo -e "\n[!] $*" >&2; }
die()  { echo -e "\n[x] $*" >&2; exit 1; }

run() {
  if (( DRY_RUN )); then
    echo "  [dry-run] $*"
  else
    eval "$@"
  fi
}

write_file() {
  local dest="$1"
  shift
  if (( DRY_RUN )); then
    echo "  [dry-run] write ${dest}"
    return 0
  fi
  install -d -m 755 "$(dirname "$dest")"
  cat >"$dest"
}

chmod_file() {
  local mode="$1" dest="$2"
  (( DRY_RUN )) && return 0
  chmod "$mode" "$dest"
}

install_file() {
  local src="$1" dest="$2" mode="${3:-755}"
  if (( DRY_RUN )); then
    echo "  [dry-run] install ${src} -> ${dest}"
    return 0
  fi
  install -d -m 755 "$(dirname "$dest")"
  install -m "$mode" "$src" "$dest"
}

# Real user when invoked via sudo
real_user() {
  echo "${SUDO_USER:-${USER:-}}"
}

caller_home() {
  local u
  u="$(real_user)"
  if [[ -n "$u" && "$u" != "root" ]]; then
    getent passwd "$u" | cut -d: -f6
  else
    echo "${HOME}"
  fi
}

expand_tilde() {
  local p="$1" home
  home="$(caller_home)"
  if [[ "$p" == "~" ]]; then
    echo "$home"
  elif [[ "$p" == "~/"* ]]; then
    echo "${home}/${p:2}"
  else
    echo "$p"
  fi
}

resolve_path() {
  local p="$1"
  p="$(expand_tilde "$p")"
  if [[ ! -e "$p" ]]; then
    echo "ERROR: file not found: $1 (resolved: $p)" >&2
    return 1
  fi
  realpath "$p"
}

load_config() {
  # Defaults: repo -> system -> user (later overrides earlier)
  if [[ -r "${CURSORVMQEMU_REPO_DEFAULTS}" ]]; then
    # shellcheck disable=SC1090
    source "${CURSORVMQEMU_REPO_DEFAULTS}"
  fi
  if [[ -r "${CURSORVMQEMU_SYSTEM_DEFAULTS}" ]]; then
    # shellcheck disable=SC1090
    source "${CURSORVMQEMU_SYSTEM_DEFAULTS}"
  fi
  if [[ -r "${CURSORVMQEMU_USER_CONFIG}" ]]; then
    # shellcheck disable=SC1090
    source "${CURSORVMQEMU_USER_CONFIG}"
  fi
}

ensure_user_config_dir() {
  if (( DRY_RUN )); then
    echo "  [dry-run] mkdir -p ${CURSORVMQEMU_CONFIG_DIR}"
    return 0
  fi
  install -d -m 700 "${CURSORVMQEMU_CONFIG_DIR}"
}

save_user_config_kv() {
  local key="$1" value="$2"
  ensure_user_config_dir
  if (( DRY_RUN )); then
    echo "  [dry-run] set ${key}=${value} in ${CURSORVMQEMU_USER_CONFIG}"
    return 0
  fi
  touch "${CURSORVMQEMU_USER_CONFIG}"
  chmod 600 "${CURSORVMQEMU_USER_CONFIG}"
  if grep -q "^${key}=" "${CURSORVMQEMU_USER_CONFIG}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${CURSORVMQEMU_USER_CONFIG}"
  else
    echo "${key}=${value}" >>"${CURSORVMQEMU_USER_CONFIG}"
  fi
}

# Detect libvirt default storage pool name and path
detect_default_pool() {
  local pool_name="${1:-default}"
  local pool_path=""

  if command -v virsh >/dev/null 2>&1; then
    pool_path="$(virsh -c qemu:///system pool-dumpxml "${pool_name}" 2>/dev/null \
      | awk -F'[<>]' '/<path>/ {print $3; exit}')"
    if [[ -n "${pool_path}" ]]; then
      echo "${pool_name}|${pool_path}"
      return 0
    fi
  fi

  # Fallback: common libvirt default
  pool_path="/var/lib/libvirt/images"
  echo "${pool_name}|${pool_path}"
}

get_default_pool_name() {
  detect_default_pool | cut -d'|' -f1
}

get_default_pool_path() {
  detect_default_pool | cut -d'|' -f2
}

prompt_default() {
  local prompt="$1" default="$2" result
  read -r -p "${prompt} [${default}]: " result
  echo "${result:-$default}"
}

prompt_yes_no() {
  local prompt="$1" default="${2:-y}" answer
  local hint="Y/n"
  [[ "${default}" == "n" ]] && hint="y/N"
  read -r -p "${prompt} [${hint}]: " answer
  answer="${answer:-$default}"
  case "${answer}" in
    y|Y|yes|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

find_isos_in_dirs() {
  local dirs="$1"
  local IFS=':'
  local d
  for d in ${dirs}; do
    d="$(expand_tilde "$d")"
    [[ -d "$d" ]] || continue
    find "$d" -maxdepth 2 -type f \( -iname '*.iso' -o -iname '*.ISO' \) 2>/dev/null
  done | sort -u
}

libvirtd_recovery_hint() {
  cat <<'EOF'

If libvirtd appears hung or VMs fail to start:
  sudo systemctl stop libvirtd libvirtd.socket virtqemud virtqemud.socket
  sudo systemctl reset-failed libvirtd virtqemud 2>/dev/null || true
  sudo systemctl start virtlogd virtlogd.socket virtlockd virtlockd.socket
  sudo systemctl start virtnetworkd virtnetworkd.socket
  sudo systemctl start libvirtd.socket libvirtd virtqemud.socket virtqemud
  virsh -c qemu:///system list --all

On AMD hosts, nested KVM may require a reboot after install:
  sudo reboot
EOF
}

is_amd_cpu() { grep -qi amd /proc/cpuinfo; }

is_live_session() {
  [[ -f /cdrom/casper/filesystem.size || -d /rofs || -n "${LIVE_SESSION:-}" ]]
}

nested_still_on() {
  local param val
  for param in /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested; do
    [[ -f "$param" ]] || continue
    val=$(cat "$param")
    [[ "$val" == "0" || "$val" == "N" ]] || return 0
  done
  return 1
}

log_nested_state() {
  local param
  for param in /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested; do
    [[ -f "$param" ]] || continue
    log "nested ${param} -> $(cat "$param")"
  done
}

detect_qemu_machine() {
  local m
  if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    m=$(qemu-system-x86_64 -machine help 2>/dev/null | awk '/pc-q35/{print $1; exit}')
  fi
  echo "${m:-pc-q35}"
}
