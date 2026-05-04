#!/usr/bin/env bash
# Interactive launcher for arch_x_motu setup scripts.

set -Eeuo pipefail

REPO_URL="${MOTU_REPO_URL:-https://github.com/Puneethkethanapalli/arch_x_motu.git}"
SOURCE_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SOURCE_PATH")" >/dev/null 2>&1 && pwd -P || pwd -P)"
REPO_ROOT="$SCRIPT_DIR"
SCRIPTS_DIR="$REPO_ROOT/scripts"

LIST_ONLY=0
ASSUME_ALL=0
REPORT_DIR="${MOTU_REPORT_DIR:-}"
REPORT_FILE=""
INPUT_FD=0
BOOTSTRAP_TMP_DIR=""

declare -a SCRIPT_PATHS=()
declare -a SCRIPT_NAMES=()
declare -a SCRIPT_DESCRIPTIONS=()
declare -a SCRIPT_RUNNERS=()
declare -a SELECTED_INDICES=()
declare -a RESULT_NAMES=()
declare -a RESULT_STATUSES=()
declare -a RESULT_DURATIONS=()

fail() {
  printf '[x] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage:
  ./run.sh
  ./run.sh --list
  ./run.sh --all

One-line public repo command:
  curl -fsSL https://raw.githubusercontent.com/Puneethkethanapalli/arch_x_motu/main/run.sh | bash

Options:
  --list              Show discovered scripts without running anything.
  --all               Run every discovered script without prompting.
  --report-dir DIR    Write the run report to DIR.
  -h, --help          Show this help.

Script metadata, placed near the top of files in scripts/:
  # motu:name=Friendly Name
  # motu:description=Short explanation
  # motu:runner=user

Runner values:
  user    Run as the current user. This is the default.
  sudo    Run with sudo when the launcher is not already root.
  root    Same behavior as sudo.
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      --list)
        LIST_ONLY=1
        ;;
      --all)
        ASSUME_ALL=1
        ;;
      --report-dir)
        shift
        [[ $# -gt 0 ]] || fail "--report-dir needs a directory path."
        REPORT_DIR="$1"
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
    shift
  done
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

bootstrap_from_public_repo_if_needed() {
  local status

  [[ -d "$SCRIPTS_DIR" ]] && return

  need_command git
  BOOTSTRAP_TMP_DIR="$(mktemp -d)"
  trap cleanup_bootstrap EXIT

  printf '[+] Cloning %s\n' "$REPO_URL" >&2
  git clone --depth 1 "$REPO_URL" "$BOOTSTRAP_TMP_DIR" >/dev/null

  export MOTU_BOOTSTRAPPED=1
  export MOTU_ORIGINAL_CWD="${MOTU_ORIGINAL_CWD:-$(pwd -P)}"
  export MOTU_REPORT_DIR="${MOTU_REPORT_DIR:-${MOTU_ORIGINAL_CWD}/motu-reports}"

  bash "$BOOTSTRAP_TMP_DIR/run.sh" "$@"
  status=$?
  exit "$status"
}

cleanup_bootstrap() {
  [[ -n "$BOOTSTRAP_TMP_DIR" && -d "$BOOTSTRAP_TMP_DIR" ]] && rm -rf "$BOOTSTRAP_TMP_DIR"
}

open_prompt_input() {
  if tty_available; then
    exec 3</dev/tty
    INPUT_FD=3
  elif [[ -t 0 ]]; then
    INPUT_FD=0
  else
    fail "Interactive selection needs a terminal."
  fi
}

tty_available() {
  { true </dev/tty; } 2>/dev/null
}

prompt() {
  if tty_available; then
    printf '%s' "$*" >/dev/tty
  else
    printf '%s' "$*"
  fi
}

metadata_value() {
  local file="$1"
  local key="$2"

  awk -v key="$key" '
    BEGIN { prefix = "# motu:" key "=" }
    index($0, prefix) == 1 {
      print substr($0, length(prefix) + 1)
      exit
    }
  ' "$file"
}

default_name_for_script() {
  local file="$1"
  local base stem

  base="${file##*/}"
  stem="${base%.sh}"
  printf '%s' "${stem//_/ }"
}

normalize_runner() {
  local runner="${1:-user}"

  runner="$(printf '%s' "$runner" | tr '[:upper:]' '[:lower:]')"
  case "$runner" in
    user|sudo|root)
      printf '%s' "$runner"
      ;;
    *)
      printf 'user'
      ;;
  esac
}

discover_scripts() {
  local path name description runner

  mapfile -t SCRIPT_PATHS < <(find "$SCRIPTS_DIR" -maxdepth 1 -type f -name '*.sh' -print | sort)
  [[ ${#SCRIPT_PATHS[@]} -gt 0 ]] || fail "No scripts found in $SCRIPTS_DIR."

  for path in "${SCRIPT_PATHS[@]}"; do
    name="$(metadata_value "$path" name)"
    description="$(metadata_value "$path" description)"
    runner="$(metadata_value "$path" runner)"

    [[ -n "$name" ]] || name="$(default_name_for_script "$path")"
    [[ -n "$description" ]] || description="No description provided."
    runner="$(normalize_runner "$runner")"

    SCRIPT_NAMES+=("$name")
    SCRIPT_DESCRIPTIONS+=("$description")
    SCRIPT_RUNNERS+=("$runner")
  done
}

print_script_list() {
  local i number executable_mark

  printf '\nAvailable scripts from %s:\n\n' "$SCRIPTS_DIR"
  for i in "${!SCRIPT_PATHS[@]}"; do
    number=$((i + 1))
    executable_mark=""
    [[ -x "${SCRIPT_PATHS[$i]}" ]] || executable_mark=" not executable"
    printf '  %2d. %s [%s%s]\n' "$number" "${SCRIPT_NAMES[$i]}" "${SCRIPT_RUNNERS[$i]}" "$executable_mark"
    printf '      %s\n' "${SCRIPT_DESCRIPTIONS[$i]}"
  done
  printf '\n'
}

select_all_scripts() {
  local i

  SELECTED_INDICES=()
  for i in "${!SCRIPT_PATHS[@]}"; do
    SELECTED_INDICES+=("$i")
  done
}

prompt_for_selection() {
  local answer lowered token index seen invalid

  while true; do
    prompt 'Select scripts to run (example: 1 2, all, or q): '
    read -r -u "$INPUT_FD" answer || exit 1
    lowered="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"

    case "$lowered" in
      q|quit|exit)
        printf 'No scripts selected.\n'
        exit 0
        ;;
      a|all)
        select_all_scripts
        return
        ;;
    esac

    answer="${answer//,/ }"
    SELECTED_INDICES=()
    seen=" "
    invalid=0

    for token in $answer; do
      if [[ ! "$token" =~ ^[0-9]+$ ]]; then
        printf '[!] Invalid selection: %s\n' "$token" >&2
        invalid=1
        continue
      fi

      if (( token < 1 || token > ${#SCRIPT_PATHS[@]} )); then
        printf '[!] Selection out of range: %s\n' "$token" >&2
        invalid=1
        continue
      fi

      index=$((token - 1))
      if [[ "$seen" != *" $index "* ]]; then
        SELECTED_INDICES+=("$index")
        seen+="$index "
      fi
    done

    if (( invalid == 0 && ${#SELECTED_INDICES[@]} > 0 )); then
      return
    fi
  done
}

default_report_dir() {
  if [[ -n "$REPORT_DIR" ]]; then
    printf '%s' "$REPORT_DIR"
  elif [[ "${MOTU_BOOTSTRAPPED:-0}" == "1" ]]; then
    printf '%s/motu-reports' "${MOTU_ORIGINAL_CWD:-$(pwd -P)}"
  else
    printf '%s/reports' "$REPO_ROOT"
  fi
}

prepare_report() {
  local timestamp idx

  REPORT_DIR="$(default_report_dir)"
  mkdir -p "$REPORT_DIR"
  timestamp="$(date +%Y%m%d-%H%M%S)"
  REPORT_FILE="$REPORT_DIR/run-${timestamp}.log"

  {
    printf 'arch_x_motu run report\n'
    printf 'started_at=%s\n' "$(date -Is)"
    printf 'repo_url=%s\n' "$REPO_URL"
    printf 'repo_path=%s\n' "$REPO_ROOT"
    printf 'scripts_path=%s\n' "$SCRIPTS_DIR"
    printf 'user=%s\n' "$(id -un 2>/dev/null || printf unknown)"
    printf 'host=%s\n' "$(hostname 2>/dev/null || printf unknown)"
    printf 'kernel=%s\n' "$(uname -srmo 2>/dev/null || uname -a)"
    if [[ -r /etc/os-release ]]; then
      awk -F= '/^(PRETTY_NAME|ID|ID_LIKE)=/ { print "os_" tolower($1) "=" $2 }' /etc/os-release
    fi
    printf '\nselected_scripts:\n'
    for idx in "${SELECTED_INDICES[@]}"; do
      printf '  - %s [%s] %s\n' "${SCRIPT_NAMES[$idx]}" "${SCRIPT_RUNNERS[$idx]}" "${SCRIPT_PATHS[$idx]#$REPO_ROOT/}"
    done
  } > "$REPORT_FILE"
}

command_text() {
  local -a command=("$@")
  local text

  printf -v text '%q ' "${command[@]}"
  printf '%s' "${text% }"
}

run_user_script_as_original_user() {
  local script_path="$1"
  local target_user target_uid target_home

  target_user="${SUDO_USER:-}"
  [[ -n "$target_user" && "$target_user" != "root" ]] || return 1

  target_home="$(getent passwd "$target_user" | awk -F: '{print $6}')"
  target_uid="$(id -u "$target_user")"
  [[ -n "$target_home" && -n "$target_uid" ]] || return 1

  sudo -u "$target_user" env \
    "HOME=$target_home" \
    "USER=$target_user" \
    "LOGNAME=$target_user" \
    "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/${target_uid}}" \
    "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/${target_uid}/bus}" \
    bash "$script_path"
}

run_one_script() {
  local idx="$1"
  local path name runner relative start_epoch end_epoch duration status command_display
  local -a command=()

  path="${SCRIPT_PATHS[$idx]}"
  name="${SCRIPT_NAMES[$idx]}"
  runner="${SCRIPT_RUNNERS[$idx]}"
  relative="${path#$REPO_ROOT/}"

  case "$runner" in
    sudo|root)
      if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        command=(bash "$path")
      else
        command=(sudo bash "$path")
      fi
      ;;
    user)
      if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        command=(run_user_script_as_original_user "$path")
      else
        command=(bash "$path")
      fi
      ;;
  esac

  command_display="$(command_text "${command[@]}")"

  {
    printf '\n============================================================\n'
    printf 'Script: %s\n' "$name"
    printf 'Path: %s\n' "$relative"
    printf 'Runner: %s\n' "$runner"
    printf 'Command: %s\n' "$command_display"
    printf 'Started: %s\n' "$(date -Is)"
    printf '%s\n' '------------------------------------------------------------'
  } | tee -a "$REPORT_FILE"

  start_epoch="$(date +%s)"
  set +e
  if tty_available; then
    "${command[@]}" </dev/tty > >(tee -a "$REPORT_FILE") 2>&1
  else
    "${command[@]}" > >(tee -a "$REPORT_FILE") 2>&1
  fi
  status=$?
  set -e
  end_epoch="$(date +%s)"
  duration=$((end_epoch - start_epoch))

  {
    printf '%s\n' '------------------------------------------------------------'
    printf 'Finished: %s\n' "$(date -Is)"
    printf 'Exit code: %s\n' "$status"
    printf 'Duration: %ss\n' "$duration"
  } | tee -a "$REPORT_FILE"

  RESULT_NAMES+=("$name")
  RESULT_STATUSES+=("$status")
  RESULT_DURATIONS+=("$duration")
}

print_summary() {
  local i status failed=0

  {
    printf '\n============================================================\n'
    printf 'Summary\n'
    printf '%s\n' '------------------------------------------------------------'
    for i in "${!RESULT_NAMES[@]}"; do
      status="${RESULT_STATUSES[$i]}"
      if [[ "$status" == "0" ]]; then
        printf 'PASS  %s (%ss)\n' "${RESULT_NAMES[$i]}" "${RESULT_DURATIONS[$i]}"
      else
        printf 'FAIL  %s exit=%s (%ss)\n' "${RESULT_NAMES[$i]}" "$status" "${RESULT_DURATIONS[$i]}"
        failed=$((failed + 1))
      fi
    done
    printf '\nReport saved: %s\n' "$REPORT_FILE"
  } | tee -a "$REPORT_FILE"

  (( failed == 0 ))
}

main() {
  parse_args "$@"
  bootstrap_from_public_repo_if_needed "$@"
  discover_scripts

  if (( LIST_ONLY == 1 )); then
    print_script_list
    return
  fi

  if (( ASSUME_ALL == 1 )); then
    select_all_scripts
  else
    print_script_list
    open_prompt_input
    prompt_for_selection
  fi

  prepare_report
  printf '[+] Writing report to %s\n' "$REPORT_FILE"

  local idx
  for idx in "${SELECTED_INDICES[@]}"; do
    run_one_script "$idx"
  done

  print_summary
}

main "$@"
