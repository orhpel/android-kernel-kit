#!/usr/bin/env bash
# ========================================================
# Android Kernel Kit
#
# --- config-schema.sh ---
# Declarative registry of all user-configurable kit settings.
# Sourced by common.sh at the end. Do not execute.
#
# Each config_declare call describes one variable:
#   - type       bool | enum | int | string | file | dir
#   - scope      global | project | both
#                (where config-it writes it; read precedence follows)
#   - group      menu domain (General, Paths, Build, ...)
#   - default    initial value
#   - hidden     not shown in config-it (used for STATE vars)
#
# Naming: KIT_<DOMAIN>_<ROLE>_<NAME>
#   ROLE = OPT   → CLI-overridable
#          CFG   → config-only, no CLI flag
#          STATE → persistent state, hidden, in .kit state section
#          INT   → internal, not declared here
# ========================================================

if [ "${_CONFIG_SCHEMA_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
_CONFIG_SCHEMA_SH_LOADED=1

# --- General -------------------------------------------------

config_declare KIT_COMMON_CFG_TOOLCHAIN enum \
  --group General --scope project --default default \
  --options-from-dir "${KIT_DIR}/toolchains" \
  --desc "Toolchain profile to load for this project"

config_declare KIT_COMMON_CFG_ADB_WAIT_INTERVAL int \
  --group ADB --scope global --default 2 --min 1 \
  --desc "Seconds between adb get-state polls"

config_declare KIT_COMMON_OPT_NO_TMUX bool \
  --group General --scope both --default 0 \
  --desc "Disable tmux auto-launch for streamed builds"

config_declare KIT_COMMON_CFG_NERDFONT bool \
  --group General --scope global --default 0 \
  --desc "Use NerdFont glyphs for the pipeline progress line"

# --- Paths ---------------------------------------------------

config_declare KIT_COMMON_CFG_LOG_DIR dir \
  --group Paths --scope both --default logs \
  --desc "Session log directory (relative to project root, or absolute)"

config_declare KIT_BUILD_CFG_ARCHIVE_DIR dir \
  --group Paths --scope both --default build_archive \
  --desc "Root directory for archived builds"

config_declare KIT_BUILD_CFG_DTB_TOOL file \
  --group Paths --scope global \
  --default "$HOME/Projects/dtbTool-lineage17.1/dtbtool" \
  --desc "dtbTool binary (LineageOS fork)"

config_declare KIT_PACK_CFG_AIK_DIR dir \
  --group Paths --scope global \
  --default "$HOME/Projects/Android-Image-Kitchen" \
  --desc "Android Image Kitchen root"

# --- Logging -------------------------------------------------

config_declare KIT_LOG_CFG_ROTATE_MAX_SIZE int \
  --group Log --scope global --default 1048576 --min 0 \
  --desc "Max session log size in bytes before rotation (0 = unlimited)"

config_declare KIT_LOG_CFG_ROTATE_MAX_COUNT int \
  --group Log --scope global --default 20 --min 1 \
  --desc "Max retained session logs"

config_declare KIT_LOG_OPT_TIMESTAMP bool \
  --group Log --scope both --default 1 \
  --desc "Append timestamp to pulled log filenames"

# --- Build ---------------------------------------------------

config_declare KIT_BUILD_CFG_AUTO_ARCHIVE bool \
  --group Build --scope both --default 1 \
  --desc "Archive each successful build"

config_declare KIT_BUILD_CFG_AUTO_DTB_APPEND bool \
  --group Build --scope both --default 1 \
  --desc "Auto-generate boot-dt.img when kernel target has no appended DTB"

config_declare KIT_BUILD_CFG_DTB_DIR dir \
  --group Build --scope project --default "" \
  --desc "DTS source directory (empty = arch/<ARCH>/boot/dts)"

config_declare KIT_BUILD_CFG_DEFAULT_TARGETS string \
  --group Build --scope project --default "zImage dtbs" \
  --desc "Default make targets when none are given"

config_declare KIT_BUILD_OPT_LOCALVERSION string \
  --group Build --scope project --default "" \
  --desc "Kernel localversion suffix"

# --- Clean ---------------------------------------------------

config_declare KIT_CLEAN_CFG_BACKUP_FILE string \
  --group Clean --scope both --default config.BAK \
  --desc "Backup filename for .config during cleanup"

config_declare KIT_CLEAN_OPT_NO_RESTORE bool \
  --group Clean --scope both --default 0 \
  --desc "Do not restore .config after cleanup"

config_declare KIT_CLEAN_OPT_NO_BACKUP bool \
  --group Clean --scope both --default 0 \
  --desc "Skip the .config backup entirely (implies no-restore)"

# --- Pack ----------------------------------------------------

config_declare KIT_PACK_CFG_REPACK_TOOL enum \
  --group Pack --scope both --default aik \
  --options "aik magisk" \
  --desc "Backend used to unpack/repack boot images"

config_declare KIT_PACK_CFG_DEFAULT_BOOT_IMAGE file \
  --group Pack --scope project --default boot.img \
  --desc "Source boot image when none is given"

# --- Flash ---------------------------------------------------

config_declare KIT_FLASH_CFG_DEFAULT_IMAGE string \
  --group Flash --scope project --default image-new.img \
  --desc "Image flashed when no PATH is given"

config_declare KIT_FLASH_CFG_DEVICE_PATH string \
  --group Flash --scope both --default /sdcard/boot.img \
  --desc "On-device staging path for pushed images"

config_declare KIT_FLASH_CFG_BOOT_DEVICE string \
  --group Flash --scope project --default /dev/block/mmcblk0p20 \
  --desc "Target boot partition on the device"

config_declare KIT_FLASH_CFG_REBOOT_DELAY int \
  --group Flash --scope global --default 3 --min 0 \
  --desc "Pre-reboot countdown in seconds"

# --- Menu ----------------------------------------------------

config_declare KIT_MENU_CFG_SYMBOL_CHECKED   string --group Menu --scope global --default "✅" --desc "Checked-state glyph"
config_declare KIT_MENU_CFG_SYMBOL_UNCHECKED string --group Menu --scope global --default "⬛" --desc "Unchecked-state glyph"
config_declare KIT_MENU_CFG_SYMBOL_SUBMENU   string --group Menu --scope global --default "→"  --desc "Submenu marker"
config_declare KIT_MENU_CFG_COLOR_CURSOR     string --group Menu --scope global --default "212" --desc "gum cursor foreground colour"
config_declare KIT_MENU_CFG_COLOR_SELECTED   string --group Menu --scope global --default ""    --desc "gum selected-line foreground colour"
config_declare KIT_MENU_CFG_COLOR_ITEM       string --group Menu --scope global --default ""    --desc "gum item foreground colour"
config_declare KIT_MENU_CFG_COLOR_HEADER     string --group Menu --scope global --default ""    --desc "gum header foreground colour"

# --- Stream --------------------------------------------------

config_declare KIT_STREAM_CFG_SPLIT_MIN_WIDTH int    --group Stream --scope global --default 100 --min 40 --desc "Min terminal width for a horizontal split"
config_declare KIT_STREAM_CFG_SPLIT_SIZE      string --group Stream --scope global --default "40%" --desc "Pane size (percent or lines)"
config_declare KIT_STREAM_CFG_USE_STDBUF      bool   --group Stream --scope global --default 1     --desc "Line-buffer child via stdbuf when available"
config_declare KIT_STREAM_CFG_ERROR_CONTEXT   int    --group Stream --scope global --default 15 --min 0 --desc "Context lines around 'error:' on failure"
config_declare KIT_STREAM_CFG_TMUX_SESSION    string --group Stream --scope global --default ""    --desc "tmux session name (empty = kit-build-<pid>)"

# --- State (hidden, managed automatically) -------------------

config_declare KIT_BUILD_STATE_BUILDNO   int --group State --scope project --default 0 --hidden --desc "Monotonic build counter"
config_declare KIT_BUILD_STATE_REF_LINES int --group State --scope project --default 0 --hidden --desc "Output line count of last successful build"
config_declare KIT_COMMON_STATE_NERDFONT_ASKED bool \
  --group State --scope global --default 0 --hidden \
  --desc "Whether config-it has already asked about NerdFont support"

# Canonical menu order for config-it. Groups not listed here appear
# afterwards in arbitrary order.
# shellcheck disable=SC2034  # read by config_list_groups in common.sh
KIT_CONFIG_GROUP_ORDER=(
  General
  Paths
  ADB
  Clean
  Build
  Pack
  Flash
  Log
  Stream
  Menu
)