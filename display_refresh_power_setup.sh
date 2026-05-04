#!/usr/bin/env bash
# Switch the internal laptop display refresh rate based on AC power.
# AC power: 120 Hz. Battery: 60 Hz.

set -Eeuo pipefail

SCRIPT_NAME="${0##*/}"
INSTALL_PATH="${HOME}/.local/bin/display-refresh-power"
SERVICE_PATH="${HOME}/.config/systemd/user/display-refresh-power.service"
AC_HZ="${DISPLAY_REFRESH_AC_HZ:-120}"
BATTERY_HZ="${DISPLAY_REFRESH_BATTERY_HZ:-60}"
POLL_SECONDS="${DISPLAY_REFRESH_POLL_SECONDS:-5}"

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
  ./$SCRIPT_NAME
  ./$SCRIPT_NAME --status
  ./$SCRIPT_NAME --apply
  ./$SCRIPT_NAME --uninstall

What it does:
  - Installs a user systemd service, not a root service.
  - Uses kscreen-doctor on KDE/Wayland or KDE/X11.
  - Falls back to xrandr only on X11 sessions.
  - Sets the internal panel to ${AC_HZ} Hz on AC power.
  - Sets the internal panel to ${BATTERY_HZ} Hz on battery.

Options:
  --install     Install and start the user service. This is the default.
  --status      Print power/display/service state without changing refresh.
  --apply       Apply the correct refresh rate once for the current power state.
  --daemon      Internal mode used by the systemd user service.
  --uninstall   Stop and remove the user service and installed script copy.
  -h, --help    Show this help.

Environment overrides:
  DISPLAY_REFRESH_AC_HZ=120
  DISPLAY_REFRESH_BATTERY_HZ=60
  DISPLAY_REFRESH_POLL_SECONDS=5
EOF
}

ACTION="install"
case "${1:-}" in
  "")
    ;;
  --install)
    ACTION="install"
    ;;
  --status)
    ACTION="status"
    ;;
  --apply)
    ACTION="apply"
    ;;
  --daemon)
    ACTION="daemon"
    ;;
  --uninstall)
    ACTION="uninstall"
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

user_service_enabled_state() {
  local state
  state="$(systemctl --user is-enabled "$1" 2>/dev/null || true)"
  [[ -n "$state" ]] && printf '%s' "$state" || printf 'not-found'
}

user_service_active_state() {
  local state
  state="$(systemctl --user is-active "$1" 2>/dev/null || true)"
  [[ -n "$state" ]] && printf '%s' "$state" || printf 'inactive'
}

require_not_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    fail "Run this as your normal desktop user, not with sudo. Display refresh changes belong to the user session."
  fi
}

power_state() {
  local found_mains=0
  local d type online

  for d in /sys/class/power_supply/*; do
    [[ -d "$d" ]] || continue
    type="$(cat "$d/type" 2>/dev/null || true)"
    [[ "$type" == "Mains" ]] || continue
    found_mains=1
    online="$(cat "$d/online" 2>/dev/null || printf '0')"
    if [[ "$online" == "1" ]]; then
      printf 'ac\n'
      return
    fi
  done

  if [[ "$found_mains" == "1" ]]; then
    printf 'battery\n'
    return
  fi

  # Fallback for machines that expose USB-C charging without a Mains supply.
  for d in /sys/class/power_supply/*; do
    [[ -d "$d" ]] || continue
    type="$(cat "$d/type" 2>/dev/null || true)"
    [[ "$type" != "Battery" ]] || continue
    online="$(cat "$d/online" 2>/dev/null || printf '0')"
    if [[ "$online" == "1" ]]; then
      printf 'ac\n'
      return
    fi
  done

  printf 'battery\n'
}

target_hz_for_power() {
  case "$(power_state)" in
    ac) printf '%s\n' "$AC_HZ" ;;
    *) printf '%s\n' "$BATTERY_HZ" ;;
  esac
}

kscreen_json() {
  kscreen-doctor -j 2>/dev/null
}

kscreen_output_name() {
  jq -r '
    (
      [.outputs[] | select(.connected == true and .enabled == true and (.name | ascii_downcase | test("^(edp|lvds|dsi)")))][0]
      // [.outputs[] | select(.connected == true and .enabled == true and .type == 7)][0]
    ).name // empty
  '
}

kscreen_mode_for_target() {
  local output_name="$1"
  local target_hz="$2"

  jq -r --arg output_name "$output_name" --argjson target_hz "$target_hz" '
    .outputs[]
    | select(.name == $output_name)
    | . as $output
    | $output.size.width as $width
    | $output.size.height as $height
    | [
        $output.modes[]
        | select(.size.width == $width and .size.height == $height)
        | select(.refreshRate >= ($target_hz - 2) and .refreshRate <= ($target_hz + 2))
        | . + {distance: ((.refreshRate - $target_hz) | if . < 0 then . * -1 else . end)}
      ]
    | sort_by(.distance)
    | .[0].id // empty
  '
}

kscreen_current_summary() {
  jq -r '
    (
      [.outputs[] | select(.connected == true and .enabled == true and (.name | ascii_downcase | test("^(edp|lvds|dsi)")))][0]
      // [.outputs[] | select(.connected == true and .enabled == true and .type == 7)][0]
    ) as $output
    | if $output == null then
        "output=none"
      else
        ($output.currentModeId) as $mode_id
        | ($output.modes[] | select(.id == $mode_id)) as $mode
        | "output=\($output.name) current=\($mode.name) refresh=\($mode.refreshRate) scale=\($output.scale)"
      end
  '
}

apply_with_kscreen() {
  local target_hz="$1"
  local json output_name mode_id

  need_command kscreen-doctor
  need_command jq

  json="$(kscreen_json)"
  [[ -n "$json" ]] || fail "kscreen-doctor did not return display data."

  output_name="$(printf '%s\n' "$json" | kscreen_output_name)"
  [[ -n "$output_name" ]] || fail "Could not find an enabled internal display output."

  mode_id="$(printf '%s\n' "$json" | kscreen_mode_for_target "$output_name" "$target_hz")"
  [[ -n "$mode_id" ]] || fail "No ${target_hz} Hz mode found for current resolution on $output_name."

  kscreen-doctor "output.${output_name}.mode.${mode_id}" >/dev/null
  log "Set $output_name to ${target_hz} Hz with kscreen-doctor mode $mode_id."
}

xrandr_output_name() {
  xrandr --query 2>/dev/null | awk '
    $2 == "connected" && $1 ~ /^(eDP|EDP|LVDS|DSI)/ { print $1; found=1; exit }
  '
}

xrandr_current_resolution() {
  local output_name="$1"

  xrandr --query 2>/dev/null | awk -v output_name="$output_name" '
    $1 == output_name && $2 == "connected" {
      for (i = 3; i <= NF; i++) {
        if ($i ~ /^[0-9]+x[0-9]+\+/) {
          split($i, parts, "+")
          print parts[1]
          exit
        }
      }
    }
  '
}

apply_with_xrandr() {
  local target_hz="$1"
  local output_name resolution

  need_command xrandr

  if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
    fail "Refusing xrandr fallback on Wayland; xrandr would only affect Xwayland."
  fi

  output_name="$(xrandr_output_name)"
  [[ -n "$output_name" ]] || fail "Could not find an enabled display output with xrandr."

  resolution="$(xrandr_current_resolution "$output_name")"
  [[ -n "$resolution" ]] || fail "Could not determine current resolution for $output_name."

  xrandr --output "$output_name" --mode "$resolution" --rate "$target_hz"
  log "Set $output_name to ${target_hz} Hz with xrandr."
}

apply_once() {
  local target_hz
  target_hz="$(target_hz_for_power)"

  if command -v kscreen-doctor >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && kscreen-doctor -j >/dev/null 2>&1; then
    apply_with_kscreen "$target_hz"
  else
    apply_with_xrandr "$target_hz"
  fi
}

status() {
  header "Refresh Power Status"
  printf 'power state                  %s\n' "$(power_state)"
  printf 'target refresh               %s Hz\n' "$(target_hz_for_power)"
  printf 'session type                 %s\n' "${XDG_SESSION_TYPE:-unknown}"
  printf 'current desktop              %s\n' "${XDG_CURRENT_DESKTOP:-unknown}"

  if command -v kscreen-doctor >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && kscreen-doctor -j >/dev/null 2>&1; then
    printf 'display tool                 kscreen-doctor\n'
    kscreen_json | kscreen_current_summary
  elif command -v xrandr >/dev/null 2>&1; then
    printf 'display tool                 xrandr\n'
    printf 'output                       %s\n' "$(xrandr_output_name)"
  else
    printf 'display tool                 none\n'
  fi

  printf 'user service enabled         %s\n' "$(user_service_enabled_state display-refresh-power.service)"
  printf 'user service active          %s\n' "$(user_service_active_state display-refresh-power.service)"
}

install_service() {
  local source_path

  header "Installing refresh power service"
  need_command systemctl
  source_path="$(realpath "${BASH_SOURCE[0]}")"

  mkdir -p "$(dirname "$INSTALL_PATH")" "$(dirname "$SERVICE_PATH")"
  install -m 755 "$source_path" "$INSTALL_PATH"

  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Switch internal display refresh rate based on AC power
After=graphical-session.target plasma-workspace.target plasma-workspace-wayland.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=$INSTALL_PATH --daemon
Restart=on-failure
RestartSec=2

[Install]
WantedBy=graphical-session.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now display-refresh-power.service

  log "Installed $INSTALL_PATH"
  log "Enabled user service display-refresh-power.service"
  apply_once
  status
}

uninstall_service() {
  header "Uninstalling refresh power service"
  need_command systemctl

  systemctl --user disable --now display-refresh-power.service 2>/dev/null || true
  rm -f "$SERVICE_PATH"
  rm -f "$INSTALL_PATH"
  systemctl --user daemon-reload
  log "Removed display-refresh-power user service and installed script copy."
}

daemon_loop() {
  local last_state=""
  local current_state=""

  log "Starting refresh monitor: AC=${AC_HZ}Hz battery=${BATTERY_HZ}Hz poll=${POLL_SECONDS}s"

  while true; do
    current_state="$(power_state)"
    if [[ "$current_state" != "$last_state" ]]; then
      if ! apply_once; then
        warn "Failed to apply refresh for power state: $current_state"
      fi
      last_state="$current_state"
    fi
    sleep "$POLL_SECONDS"
  done
}

main() {
  require_not_root

  case "$ACTION" in
    install)
      install_service
      ;;
    status)
      status
      ;;
    apply)
      apply_once
      status
      ;;
    daemon)
      daemon_loop
      ;;
    uninstall)
      uninstall_service
      ;;
  esac
}

main "$@"
