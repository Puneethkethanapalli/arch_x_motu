#!/usr/bin/env bash
# motu:name=Arch CPU Performance Setup
# motu:description=Enable power-profiles-daemon performance mode and Intel turbo on Arch-family systems.
# motu:runner=sudo
# Arch-family CPU turbo/performance setup.
# Keeps power-profiles-daemon as the active power manager, disables
# auto-cpufreq, enables Intel turbo, and verifies the resulting CPU limits.

set -Eeuo pipefail

SCRIPT_NAME="${0##*/}"
TURBO_PATH="/sys/devices/system/cpu/intel_pstate/no_turbo"
SUPPORTED_DISTROS=("arch" "cachyos" "endeavouros" "manjaro" "garuda")

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  NC=""
fi

log() { printf '%s[+]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YELLOW" "$NC" "$*"; }
fail() {
  printf '%s[x]%s %s\n' "$RED" "$NC" "$*" >&2
  exit 1
}
header() {
  printf '\n%s== %s ==%s\n' "$BLUE" "$*" "$NC"
}

usage() {
  cat <<EOF
Usage:
  sudo ./$SCRIPT_NAME
  ./$SCRIPT_NAME --verify-only

Alternative if the executable bit is missing:
  sudo bash $SCRIPT_NAME
  bash $SCRIPT_NAME --verify-only

What it does:
  - Supports Arch-family distros only.
  - Disables auto-cpufreq.service if it exists.
  - Enables power-profiles-daemon.service and sets performance mode.
  - Enables Intel turbo for the current boot.

Options:
  --verify-only   Print current state without changing anything.
  -h, --help      Show this help.
EOF
}

VERIFY_ONLY=0
case "${1:-}" in
  "")
    ;;
  --verify-only)
    VERIFY_ONLY=1
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    fail "Unknown option: $1"
    ;;
esac

need_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

is_supported_distro() {
  local id="${1,,}"
  local id_like=" ${2,,} "
  local supported

  for supported in "${SUPPORTED_DISTROS[@]}"; do
    if [[ "$id" == "$supported" ]]; then
      return 0
    fi
  done

  [[ "$id_like" == *" arch "* ]]
}

detect_distro() {
  [[ -r /etc/os-release ]] || fail "Cannot detect distro: /etc/os-release is missing."

  # shellcheck disable=SC1091
  . /etc/os-release

  local distro_id="${ID:-unknown}"
  local distro_like="${ID_LIKE:-}"

  if ! is_supported_distro "$distro_id" "$distro_like"; then
    fail "Unsupported distro '$distro_id'. This script supports Arch-family distros only."
  fi

  log "Detected supported distro: $distro_id"
}

require_root_for_setup() {
  if (( VERIFY_ONLY == 0 )) && [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    fail "Run setup as root: sudo ./$SCRIPT_NAME"
  fi
}

service_exists() {
  systemctl list-unit-files "$1" >/dev/null 2>&1
}

service_enabled_state() {
  local state
  state="$(systemctl is-enabled "$1" 2>/dev/null || true)"
  [[ -n "$state" ]] && printf '%s' "$state" || printf 'not-found'
}

service_active_state() {
  local state
  state="$(systemctl is-active "$1" 2>/dev/null || true)"
  [[ -n "$state" ]] && printf '%s' "$state" || printf 'inactive'
}

install_power_profiles_daemon() {
  header "Installing power-profiles-daemon"
  need_command pacman

  if command -v powerprofilesctl >/dev/null 2>&1 && service_exists power-profiles-daemon.service; then
    log "power-profiles-daemon is already installed."
    return
  fi

  log "Installing power-profiles-daemon with pacman."
  pacman -S --needed power-profiles-daemon
}

disable_auto_cpufreq() {
  header "Disabling auto-cpufreq"

  if service_exists auto-cpufreq.service; then
    systemctl disable --now auto-cpufreq.service
    log "auto-cpufreq.service disabled and stopped."
  else
    log "auto-cpufreq.service is not installed."
  fi
}

enable_power_profiles_daemon() {
  header "Enabling power-profiles-daemon"
  need_command powerprofilesctl

  systemctl enable --now power-profiles-daemon.service
  powerprofilesctl set performance
  log "power-profiles-daemon is active and set to performance."
}

enable_turbo_now() {
  header "Enabling Intel turbo"

  if [[ ! -e "$TURBO_PATH" ]]; then
    warn "$TURBO_PATH does not exist. This system may not use intel_pstate."
    return
  fi

  if [[ ! -w "$TURBO_PATH" ]]; then
    fail "Cannot write $TURBO_PATH. Run setup with sudo."
  fi

  printf '0\n' > "$TURBO_PATH"
  log "Intel turbo enabled for the current boot."
}

read_cpu_max_mhz() {
  lscpu | awk -F: '/CPU max MHz/ {gsub(/^[ \t]+/, "", $2); print $2; exit}'
}

read_base_mhz() {
  local base_khz
  base_khz="$(cat /sys/devices/system/cpu/cpu0/cpufreq/base_frequency 2>/dev/null || true)"

  if [[ "$base_khz" =~ ^[0-9]+$ ]]; then
    awk -v khz="$base_khz" 'BEGIN { printf "%.4f\n", khz / 1000 }'
  else
    printf ''
  fi
}

turbo_is_enabled() {
  [[ -r "$TURBO_PATH" ]] && [[ "$(cat "$TURBO_PATH")" == "0" ]]
}

cpu_max_above_base() {
  local max_mhz base_mhz
  max_mhz="$(read_cpu_max_mhz)"
  base_mhz="$(read_base_mhz)"

  [[ -n "$max_mhz" && -n "$base_mhz" ]] || return 1
  awk -v max="$max_mhz" -v base="$base_mhz" 'BEGIN { exit !(max > base) }'
}

performance_profile_is_active() {
  command -v powerprofilesctl >/dev/null 2>&1 || return 1
  [[ "$(powerprofilesctl get 2>/dev/null || true)" == "performance" ]]
}

print_state() {
  local turbo_state="unknown"
  local max_mhz="unknown"
  local base_mhz="unknown"
  local profile="unknown"
  local auto_enabled auto_active ppd_enabled ppd_active

  [[ -r "$TURBO_PATH" ]] && turbo_state="$(cat "$TURBO_PATH")"
  max_mhz="$(read_cpu_max_mhz)"
  [[ -n "$max_mhz" ]] || max_mhz="unknown"
  base_mhz="$(read_base_mhz)"
  [[ -n "$base_mhz" ]] || base_mhz="unknown"

  if command -v powerprofilesctl >/dev/null 2>&1; then
    profile="$(powerprofilesctl get 2>/dev/null || printf 'unknown')"
  fi

  auto_enabled="$(service_enabled_state auto-cpufreq.service)"
  auto_active="$(service_active_state auto-cpufreq.service)"
  ppd_enabled="$(service_enabled_state power-profiles-daemon.service)"
  ppd_active="$(service_active_state power-profiles-daemon.service)"

  printf 'auto-cpufreq.service          enabled=%s active=%s\n' "$auto_enabled" "$auto_active"
  printf 'power-profiles-daemon.service enabled=%s active=%s\n' "$ppd_enabled" "$ppd_active"
  printf 'power profile                 %s\n' "$profile"
  printf 'intel_pstate/no_turbo         %s\n' "$turbo_state"
  printf 'CPU base MHz                  %s\n' "$base_mhz"
  printf 'CPU max MHz                   %s\n' "$max_mhz"
}

verify_state() {
  header "Verification"
  print_state

  local ok=1

  if service_exists auto-cpufreq.service && [[ "$(service_enabled_state auto-cpufreq.service)" == "enabled" ]]; then
    warn "auto-cpufreq.service is still enabled."
    ok=0
  fi

  if service_exists auto-cpufreq.service && [[ "$(service_active_state auto-cpufreq.service)" == "active" ]]; then
    warn "auto-cpufreq.service is still active."
    ok=0
  fi

  if [[ "$(service_enabled_state power-profiles-daemon.service)" != "enabled" ]]; then
    warn "power-profiles-daemon.service is not enabled."
    ok=0
  fi

  if [[ "$(service_active_state power-profiles-daemon.service)" != "active" ]]; then
    warn "power-profiles-daemon.service is not active."
    ok=0
  fi

  if ! performance_profile_is_active; then
    warn "Power profile is not performance."
    ok=0
  fi

  if [[ -e "$TURBO_PATH" ]] && ! turbo_is_enabled; then
    warn "Intel turbo is disabled."
    ok=0
  fi

  if [[ -e "$TURBO_PATH" ]] && ! cpu_max_above_base; then
    warn "CPU max MHz does not appear to be above base MHz."
    ok=0
  fi

  if (( ok == 1 )); then
    log "Verification passed."
  else
    warn "Verification found issues. Review the lines above."
  fi
}

main() {
  need_command systemctl
  need_command lscpu
  detect_distro
  require_root_for_setup

  if (( VERIFY_ONLY == 1 )); then
    verify_state
    return
  fi

  install_power_profiles_daemon
  disable_auto_cpufreq
  enable_power_profiles_daemon
  enable_turbo_now
  verify_state
}

main "$@"
