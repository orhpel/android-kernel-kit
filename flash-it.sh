#!/usr/bin/env bash
# ========================================================
# Android Kernel Kit
#
# flash-it.sh
# Flash a boot image to the boot partition of the
# currently connected Android device via adb.
#
# ========================================================

# --- Defaults -------------------------------------------

device_path="/sdcard/boot.img"
boot_device="/dev/block/mmcblk0p20"

target_path=""
skip_transfer=0
keep=0
force=0
silent=0
verbose=0
no_reboot=0

# --- Help -----------------------------------------------

usage() {
  cat <<'EOF'
flash-it.sh - flash a boot image to an Android device via adb

USAGE
    flash-it.sh [OPTIONS] [--] [PATH]

DESCRIPTION
    Push a boot image to the device and flash it to the boot
    partition. By default the image is removed from the device
    afterwards and the device is rebooted.

ARGUMENTS
    PATH    Path to the boot image. Interpreted as a local path
            by default, or as an on-device path when
            --skip-transfer is given. Optional unless
            --skip-transfer is used.
            Default: KIT_FLASH_CFG_DEFAULT_IMAGE from the kit
            configuration (image-new.img).

OPTIONS
    -t, --skip-transfer
        Do not push the image. PATH is interpreted as a path on
        the device. Implies --keep. Makes PATH mandatory.

    -k, --keep
        Keep the image on the device after flashing. Ignored
        when --skip-transfer is used.

    -b, --boot-device DEVICE
        Target partition on the device.
        Default: KIT_FLASH_CFG_BOOT_DEVICE from the kit
        configuration (/dev/block/mmcblk0p20).

    -f, --force
        Skip the Android boot image magic check.

    -r, --no-reboot
        Do not reboot the device after a successful flash.

    -s, --silent
        Only print warnings and errors. Also suppresses the
        reboot countdown; the device is still rebooted unless
        --no-reboot is given.

    -v, --verbose
        Show raw adb output on the terminal. Without this flag,
        adb output only lands in the log.

    -h, --help
        Show this help and exit.

EXAMPLES
    flash-it.sh boot.img
        Push ./boot.img, flash it, remove it and reboot.

    flash-it.sh --keep boot.img
        Push ./boot.img, flash it, and keep it on the device.

    flash-it.sh -t /sdcard/boot.img
        Flash a file that is already present on the device.

    flash-it.sh -rs boot.img
        Flash silently and skip the reboot.

    flash-it.sh -b /dev/block/mmcblk0p21 boot.img
        Flash ./boot.img to an alternate partition.

EXIT STATUS
    0   success
    1   error (invalid arguments, adb failure, flash failure)
EOF
}

# --- Save original args ---------------------------------

orig_args=("$@")

# --- Common helpers -------------------------------------

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/common.sh"

# --help must work outside a project too.
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

cd_project_root || exit 1

# Resolve kit configuration (schema defaults, .kit files, environment).
config_load

log_init "$(basename -- "$0")" "${orig_args[@]}"

# Start the timer for the whole deployment.
deploy_start=$(date +%s)

# --- Defaults -------------------------------------------
# Configuration supplies the baseline; CLI flags override below.

default_image="${KIT_FLASH_CFG_DEFAULT_IMAGE:-image-new.img}"
device_path="${KIT_FLASH_CFG_DEVICE_PATH:-/sdcard/boot.img}"
boot_device="${KIT_FLASH_CFG_BOOT_DEVICE:-/dev/block/mmcblk0p20}"
reboot_delay="${KIT_FLASH_CFG_REBOOT_DELAY:-3}"

target_path=""
skip_transfer=0
keep=0
force=0
silent="${KIT_SILENT:-0}"
verbose=0
no_reboot=0

# --- Expand clustered short options ---------------------

expanded=()
expand_clustered_options expanded "tkfrsv" "b" "$@"
set -- "${expanded[@]}"

# --- Argument parsing -----------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
  -t | --skip-transfer) skip_transfer=1; shift ;;
  -k | --keep)          keep=1; shift ;;
  -f | --force)         force=1; shift ;;
  -r | --no-reboot)     no_reboot=1; shift ;;
  -s | --silent)        silent=1; shift ;;
  -v | --verbose)       verbose=1; shift ;;
  -h | --help)          usage; exit 0 ;;

  -b | --boot-device)
    if [ -z "${2:-}" ]; then
      echo "❌ Error: $1 requires a device path." >&2
      exit 1
    fi
    boot_device="${2}"
    shift 2
    ;;

  --)  shift; break ;;
  -*)  echo "❌ Unknown option: $1" >&2; exit 1 ;;
  *)   target_path="$1"; shift ;;
  esac
done

if [ $# -gt 0 ]; then
  if [ -n "$target_path" ]; then
    echo "❌ Too many arguments: '$target_path' and '$1'" >&2
    exit 1
  fi
  target_path="$1"
  shift
fi

if [ $# -gt 0 ]; then
  echo "❌ Unexpected arguments: $*" >&2
  exit 1
fi

[ "${silent}" -eq 1 ] && export KIT_SILENT=1

# Effective verbosity (silent wins)
# shellcheck disable=SC2034  # read by run_tool in common.sh
VERBOSE=$verbose
[ "${silent}" -eq 1 ] && VERBOSE=0

# --- Resolve derived state ------------------------------

if [ -z "$target_path" ]; then
  if [ "$skip_transfer" -eq 1 ]; then
    echo "❌ Error: --skip-transfer requires a PATH argument." >&2
    exit 1
  fi
  target_path="$default_image"
fi

if [ "$skip_transfer" -eq 1 ]; then
  keep=1
  device_path="$target_path"
fi

# --- Preflight checks -----------------------------------

if [ "$skip_transfer" -eq 0 ] && [ ! -f "$target_path" ]; then
  echo "❌ Invalid image: '$target_path' is not a file or does not exist!" >&2
  exit 1
fi

export ADB_SILENT="${silent}"
wait_for_adb || exit 1

# --- Magic-byte check -----------------------------------

if [ "${force:-0}" -eq 0 ]; then
  if [ "$skip_transfer" -eq 0 ]; then
    magic=$(head -c 8 -- "$target_path" 2>/dev/null || true)
  else
    magic=$(adb shell "head -c 8 '$device_path'" 2>/dev/null | tr -d '\r' || true)
  fi

  if [ "$magic" != "ANDROID!" ]; then
    echo "❌ '$target_path' does not look like an Android boot image." >&2
    echo "   Expected magic 'ANDROID!', got '${magic:-<empty>}'." >&2
    echo "   Use --force to skip this check." >&2
    exit 1
  fi
fi

# --- Run ------------------------------------------------

if [ "$skip_transfer" -eq 0 ]; then
  run_tool adb push "$target_path" "$device_path"
  [ "${silent}" -eq 0 ] && echo "💾 Transferred '$target_path' to '$device_path'."
fi

run_tool adb shell "dd if='$device_path' of='$boot_device'"
[ "${silent}" -eq 0 ] && echo "⚡ Flashed '$device_path' to '$boot_device'."

if [ "${keep:-0}" -eq 0 ]; then
  adb shell "rm -f '$device_path'" >/dev/null 2>&1
  [ "${silent}" -eq 0 ] && echo "🧹 Removed '$device_path' from the device."
fi

deploy_end=$(date +%s)
duration=$((deploy_end - deploy_start))

if [ "${no_reboot:-0}" -eq 0 ]; then
  if [ "${silent}" -eq 1 ]; then
    adb reboot >/dev/null 2>&1
  else
    if [ "${reboot_delay}" -gt 0 ]; then
      echo "Rebooting device in ${reboot_delay} seconds (CTRL-C to abort)"
			drama=("🔴" "🟡" "🟢")
      for ((i = reboot_delay; i > 0; i--)); do
        printf -- "--- ${drama[$i]:-⏱️}  %d ---\n" "$i"
        sleep 1
      done
    fi
    run_tool adb reboot
    echo "--- 🚀 Reboot ---"
  fi
fi

[ "${silent}" -eq 0 ] && echo "🎁 Deployment successful! (🕓 ${duration}s)"

exit 0
