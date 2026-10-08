#!/usr/bin/env bash
# ========================================================
# Android Kernel Kit
#
# log-it.sh
# Gets all available kernel and system logs from a
# connected device and saves them with a timestamp
#
# ========================================================

# --- Help -----------------------------------------------

usage() {
  cat <<'EOF'
log-it.sh - pulls the kernel and system logs from a connected Android device

USAGE
    log-it.sh [OPTIONS]

DESCRIPTION
    Pulls the kernel and system logs from a connected Android device and
    saves them in the log folder of the current project. Empty or
    unavailable logs are removed and reported instead of being saved.

OPTIONS
    -d, --log-dir PATH
        Directory to store the log files in.
        Default: KIT_COMMON_CFG_LOG_DIR from the kit
        configuration (logs).

    -n, --no-timestamp
        Do not append a timestamp to the log file names.
        Overrides KIT_LOG_OPT_TIMESTAMP from the kit
        configuration, which defaults to 1.

    -s, --silent
        Only print warnings and errors.

    -v, --verbose
        Show raw adb output on the terminal. Without this flag,
        adb output only lands in the log.

    -h, --help
        Show this help and exit.

EXAMPLES
    log-it.sh
        Creates the logs with a timestamp in the default log folder.

    log-it.sh -d /tmp/logs -n
        Creates the logs without a timestamp in /tmp/logs.

EXIT STATUS
    0   pass
    1   error (adb failure, permission denied, no device connected)
EOF
}

# --- Save original args ---------------------------------

orig_args=("$@")

# Load common kit
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/common.sh"

# --help must work outside a project too.
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

cd_project_root || exit 1

# Resolve kit configuration (schema defaults, .kit files, environment).
config_load

log_init "$(basename -- "$0")" "${orig_args[@]}"

# --- Defaults -------------------------------------------
# Configuration supplies the baseline; CLI flags override below.

log_dir="${KIT_COMMON_CFG_LOG_DIR:-logs}"
silent=0
verbose=0
use_timestamp="${KIT_LOG_OPT_TIMESTAMP:-1}"

# --- Argument parsing -----------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  -d | --log-dir)
    if [ -z "${2:-}" ]; then
      echo "❌ Error: $1 requires a path." >&2
      exit 1
    fi
    log_dir="$2"
    shift 2
    ;;
  -n | --no-timestamp)
    use_timestamp=0
    shift
    ;;
  -s | --silent)
    silent=1
    shift
    ;;
  -v | --verbose)
    verbose=1
    shift
    ;;
  -*)
    echo "❌ Error: Unknown option: $1" >&2
    exit 1
    ;;
  *)
    echo "❌ Error: Unexpected argument: $1" >&2
    exit 1
    ;;
  esac
done

if [ -z "${log_dir}" ]; then
  echo "❌ Error: Log directory is not set." >&2
  exit 1
fi

# shellcheck disable=SC2034  # read by run_tool in common.sh
VERBOSE=$verbose
# shellcheck disable=SC2034  # read by run_tool in common.sh
[ "${silent}" -eq 1 ] && VERBOSE=0

# --- Silent handling for ADB ----------------------------
export ADB_SILENT="${silent}"

wait_for_adb || exit 1

# --- Prepare log directory -----------------------------

if ! mkdir -p "${log_dir}" 2>/dev/null; then
  echo "❌ Error: Failed to create log directory: ${log_dir}" >&2
  if [ -e "${log_dir}" ] && [ ! -d "${log_dir}" ]; then
    echo "   Path exists but is not a directory." >&2
  else
    parent="$(dirname -- "${log_dir}")"
    if [ -e "${parent}" ] && [ ! -w "${parent}" ]; then
      echo "   Parent directory is not writable: ${parent}" >&2
    fi
  fi
  exit 1
fi

# --- Timestamp suffix -----------------------------------

if [ "${use_timestamp}" -eq 1 ]; then
  ts_suffix="_$(date +"%Y%m%d_%H%M%S")"
else
  ts_suffix=""
fi

# --- Helpers --------------------------------------------

fetch_log() {
  local name="$1"
  local remote="$2"
  local dest="${log_dir}/${name}${ts_suffix}.log"

  adb shell "${remote}" >"${dest}" 2>/dev/null

  if [ -s "${dest}" ]; then
    [ "${silent}" -eq 1 ] || echo "📃 Saved ${dest}"
  else
    rm -f "${dest}"
    [ "${silent}" -eq 1 ] || echo "⚠️  No data for '${name}'; file not saved."
  fi
}

# --- Fetch logs -----------------------------------------

fetch_log "dmesg"   "dmesg"
fetch_log "kmsg"    "cat /proc/last_kmsg"
fetch_log "ramoops" "cat /sys/fs/pstore/console-ramoops"
fetch_log "logcat"  "logcat -d -v time '*:E'"

[ "${silent}" -eq 1 ] || echo "🗂️ All log files successfully retrieved!"
