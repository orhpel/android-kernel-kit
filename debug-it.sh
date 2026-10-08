#!/usr/bin/env bash
# ========================================================
# Android Kernel Kit
#
# debug-it.sh
# Collects a broad set of debug information from a
# connected device into a timestamped subfolder of KIT_COMMON_CFG_LOG_DIR.
#
# ========================================================

# --- Help -----------------------------------------------

usage() {
  cat <<'EOF'
debug-it.sh - Collect debug information from a connected Android device

USAGE
    debug-it.sh [OPTIONS]

DESCRIPTION
    Collects a broad set of debug information (tombstones, build.prop,
    kernel/CPU/memory info, Magisk state, SELinux status, ...) from a
    connected Android device.

    All files are stored in a timestamped subdirectory of the log
    directory (KIT_COMMON_CFG_LOG_DIR by default). Short or single-line pieces of
    information are collected in a single 'summary.txt'; larger
    multi-line outputs and files are written to separate files.

    log-it.sh is invoked from within the same subdirectory to also
    collect the kernel and system logs.

    Individual items that cannot be collected produce a warning, but do
    not abort the run.

OPTIONS
    -d, --log-dir PATH
        Base directory for the debug folder.
        Default: KIT_COMMON_CFG_LOG_DIR from common.sh

    -s, --silent
        Only print warnings and errors. Forwarded to log-it.sh.

    -v, --verbose
        Show raw adb output on the terminal where applicable.
        Forwarded to log-it.sh.

    -h, --help
        Show this help and exit.

EXIT STATUS
    0   pass
    1   error (adb failure, no device connected)
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

log_dir="${KIT_COMMON_CFG_LOG_DIR}"
silent=0
verbose=0

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
[ "${silent}" -eq 1 ] && VERBOSE=0

export ADB_SILENT="${silent}"

wait_for_adb || exit 1

# --- Prepare output directory ---------------------------

timestamp="$(date +"%Y%m%d_%H%M%S")"
subdir="${log_dir}/${timestamp}"

if ! mkdir -p "${subdir}" 2>/dev/null; then
  echo "❌ Error: Failed to create debug directory: ${subdir}" >&2
  if [ -e "${subdir}" ] && [ ! -d "${subdir}" ]; then
    echo "   Path exists but is not a directory." >&2
  else
    parent="$(dirname -- "${subdir}")"
    if [ -e "${parent}" ] && [ ! -w "${parent}" ]; then
      echo "   Parent directory is not writable: ${parent}" >&2
    fi
  fi
  exit 1
fi

summary_file="${subdir}/summary.txt"
: >"${summary_file}"

[ "${silent}" -eq 1 ] || echo "📂 Collecting debug info into ${subdir}"

# --- Helpers --------------------------------------------

save_multi() {
  local name="$1"
  local remote="$2"
  local dest="${subdir}/${name}"

  adb shell "${remote}" >"${dest}" 2>/dev/null
  if [ -s "${dest}" ]; then
    [ "${silent}" -eq 1 ] || echo "📃 Saved ${dest}"
  else
    rm -f "${dest}"
    [ "${silent}" -eq 1 ] || echo "⚠️  No data for '${name}'."
  fi
}

add_summary() {
  local label="$1"
  local remote="$2"
  local value

  value=$(adb shell "${remote}" 2>/dev/null | tr -d '\r' | paste -sd ';' -)
  if [ -n "${value}" ]; then
    printf '%s: %s\n' "${label}" "${value}" >>"${summary_file}"
  else
    [ "${silent}" -eq 1 ] || echo "⚠️  No data for '${label}'."
  fi
}

copy_file() {
  local remote="$1"
  local name="${2:-$(basename -- "${remote}")}"
  local dest="${subdir}/${name}"

  if adb pull "${remote}" "${dest}" >/dev/null 2>&1 && [ -s "${dest}" ]; then
    [ "${silent}" -eq 1 ] || echo "📃 Copied ${remote} → ${dest}"
  else
    rm -f "${dest}"
    [ "${silent}" -eq 1 ] || echo "⚠️  Not available: ${remote}"
  fi
}

# --- Single-line / short info → summary.txt -------------

add_summary "adb_version"        "getprop ro.build.version.release"
add_summary "android_sdk"        "getprop ro.build.version.sdk"
add_summary "build_id"           "getprop ro.build.id"
add_summary "build_fingerprint"  "getprop ro.build.fingerprint"
add_summary "device"             "getprop ro.product.device"
add_summary "model"              "getprop ro.product.model"
add_summary "boot_mode"          "getprop ro.boot.mode"
add_summary "bootloader"         "getprop ro.bootloader"
add_summary "kernel_version"     "cat /proc/version"
add_summary "selinux"            "getenforce"
add_summary "root_uid"           "id -u"
add_summary "magisk_version"     "magisk -v"
add_summary "magisk_status"      "magisk -V"
add_summary "battery_level"      "dumpsys battery | grep level"
add_summary "uptime"             "cat /proc/uptime"

# --- Multi-line info → separate files -------------------

save_multi "getprop.txt"          "getprop"
save_multi "cpuinfo.txt"          "cat /proc/cpuinfo"
save_multi "meminfo.txt"          "cat /proc/meminfo"
save_multi "cmdline.txt"          "cat /proc/cmdline"
save_multi "mounts.txt"           "cat /proc/mounts"
save_multi "partitions.txt"       "cat /proc/partitions"
save_multi "block-devices.txt"    "ls -la /dev/block/by-name 2>/dev/null || ls -la /dev/block/platform"
save_multi "modules.txt"          "cat /proc/modules"
save_multi "filesystems.txt"      "cat /proc/filesystems"
save_multi "interrupts.txt"       "cat /proc/interrupts"
save_multi "bootconfig.txt"       "cat /proc/bootconfig"
save_multi "recovery-log.txt"     "cat /tmp/recovery.log"
save_multi "magisk-modules.txt"   "ls -la /data/adb/modules 2>/dev/null"
save_multi "tombstones-list.txt"  "ls -la /data/tombstones 2>/dev/null"
save_multi "pstore-list.txt"      "ls -la /sys/fs/pstore 2>/dev/null"
save_multi "selinux-contexts.txt" "ls -Z / 2>/dev/null"

# --- Files to copy --------------------------------------

copy_file "/system/build.prop"
copy_file "/vendor/build.prop"
copy_file "/product/build.prop"
copy_file "/system/etc/recovery.fstab"

save_multi "kernel-config.gz" "cat /proc/config.gz"

# --- Tombstones -----------------------------------------

tombstones=$(adb shell "ls /data/tombstones 2>/dev/null" 2>/dev/null | tr -d '\r')
if [ -n "${tombstones}" ]; then
  mkdir -p "${subdir}/tombstones"
  while IFS= read -r tb; do
    [ -z "$tb" ] && continue
    if adb pull "/data/tombstones/${tb}" "${subdir}/tombstones/${tb}" >/dev/null 2>&1; then
      [ "${silent}" -eq 1 ] || echo "📃 Copied tombstone: ${tb}"
    else
      [ "${silent}" -eq 1 ] || echo "⚠️  Could not copy tombstone: ${tb}"
    fi
  done <<<"${tombstones}"
else
  [ "${silent}" -eq 1 ] || echo "⚠️  No tombstones found."
fi

# --- Delegate to log-it.sh ---------------------------

pull_logs_args=(-d "${subdir}" -n)
[ "${silent}" -eq 1 ] && pull_logs_args+=(-s)
[ "${verbose}" -eq 1 ] && pull_logs_args+=(-v)

if ! "${KIT_DIR}/log-it.sh" "${pull_logs_args[@]}"; then
  echo "❌ Error: log-it.sh failed." >&2
  exit 1
fi

# --- Final output ---------------------------------------

if [ "${silent}" -eq 0 ]; then
  echo
  echo "🧾 Summary of collected information:"
  echo "----------------------------------------"
  cat "${summary_file}"
  echo "----------------------------------------"
  echo "🎁 Debug info saved in: ${subdir}"
fi

exit 0
