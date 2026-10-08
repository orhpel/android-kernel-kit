#!/usr/bin/env bash
# ========================================================
# Android Kernel Kit
#
# clean-it.sh
# Removes all files that have been created during a build
# process, as well as the current make configuration.
# Performs a "make clean && make mrproper" among other
# jobs.
# ========================================================
#

# --- Help -----------------------------------------------

usage() {
  cat <<'EOF'
clean-it.sh - clean up the build environment

USAGE
    clean-it.sh [OPTIONS]

DESCRIPTION
    Cleans the build environment and removes all files that have
    been created during a build process.

OPTIONS
    -h, --help
        Show this help and exit.

    --no-restore
        Creates a backup of the .config file, but does not restore
        it after cleanup. Can also be enabled via
        KIT_CLEAN_OPT_NO_RESTORE in the kit configuration.

    --no-backup
        Explicitly disables the backup of the .config file.
        You may save ~100kb, but now you also might lose all your
        work. Implies --no-restore. Can also be enabled via
        KIT_CLEAN_OPT_NO_BACKUP in the kit configuration.

    -s, --silent
        Suppress info output. Warnings and errors still print.
        Also set when KIT_SILENT=1 is present in the environment
        (propagated from build-it.sh -c -s).

    -v, --verbose
        Forwarded by build-it.sh for symmetry; currently a no-op.

EXAMPLES
    clean-it.sh
        Cleans the build environment and removes all files that
        have been created during a build process.

EXIT STATUS
    0   success
    1   error (invalid arguments, cleanup failure)
EOF
}
# --- Common helpers -------------------------------------
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/common.sh"

# --help must work outside a project too.
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

cd_project_root || exit 1
config_load
load_toolchain

# --- Defaults -------------------------------------------

# Configuration supplies the baseline; CLI flags override below.
no_restore="${KIT_CLEAN_OPT_NO_RESTORE:-0}"
no_backup="${KIT_CLEAN_OPT_NO_BACKUP:-0}"
backup_file="${KIT_CLEAN_CFG_BACKUP_FILE:-config.BAK}"
silent="${KIT_SILENT:-0}"

# --- Argument parsing -----------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
  --no-restore)
    no_restore=1
    shift
    ;;
  --no-backup)
    no_backup=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  -s | --silent)
    silent=1
    export KIT_SILENT=1
    shift
    ;;
  -v | --verbose)
    # Kept for flag-forwarding symmetry; nothing to print verbosely yet.
    shift
    ;;		
  *)
    echo "❌ Error: Unknown option: $1" >&2
    exit 1
    ;;
  esac
done

# --- Perform backup -------------------------------------

# `make mrproper` deletes .config. The backup is the only way back.
if [ "${no_backup}" -eq 0 ]; then
  if [ -f ".config" ]; then
    cp ".config" "${backup_file}"
  fi
else
  # No backup → nothing to restore from.
  no_restore=1
fi

# --- Remove existing kernel build -----------------------

kernel_files=(
  "zImage-dtb"
  "Image.gz-dtb"
  "zImage"
  "Image.gz"
  "Image"
  "uImage"
)
for kernel in "${kernel_files[@]}"; do
  rm -f "${BUILD_DIR}/${kernel}"
done

# --- Run make cleanups ----------------------------------

make clean && make mrproper

# --- Remove transient kit state -------------------------

rm -f "${TEMP_LOG}"
config_state_set KIT_BUILD_STATE_REF_LINES 0 >/dev/null 2>&1 || true

# --- Restore config, unless disabled --------------------

if [ "${no_restore}" -eq 0 ]; then
  if [ -f "${backup_file}" ]; then
    cp "${backup_file}" ".config"
  fi
fi

[ "${silent}" -eq 1 ] || echo "🧹 Cleanup complete"