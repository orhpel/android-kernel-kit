#!/usr/bin/env bash
# ========================================================
# Android Kernel Kit
#
# --- common.sh ---
# Common / shared variables and functions, which most scripts
# require.
# ========================================================

# shellcheck disable=SC2034

# --- Derived --------------------------------------------

# Kit directory
KIT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P)"

# Build output directory. Refined by load_toolchain() once ARCH is known.
BUILD_DIR="$PWD/arch/${ARCH:-}/boot"

# Temporary log filename
TEMP_LOG="$PWD/.log_current.tmp"

# --- Requirement checks ---------------------------------

# Require file(1) >= 5.40 for the kit's magic files.
FILE_VER=$(file --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1)
if ! printf '5.40\n%s\n' "$FILE_VER" | sort -V -C 2>/dev/null; then
  echo "❌ error: file(1) >= 5.40 required (found: ${FILE_VER:-none})." >&2
  exit 1
fi

# --- Gum requirement ------------------------------------

# Gum version that menu.sh requires. Bumped when we start using
# newer gum features.
GUM_MIN_VERSION="0.14.0"

# require_gum
#   Checks that gum is available and new enough.
#   Prints an actionable error on failure.
require_gum() {
  command -v gum >/dev/null 2>&1 || {
    echo "❌ Error: 'gum' not found in PATH." >&2
    echo "   Install: https://github.com/charmbracelet/gum" >&2
    return 1
  }
  local v
  v=$(gum --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  [ -n "$v" ] || { echo "❌ Error: could not determine gum version." >&2; return 1; }
  if ! printf '%s\n%s\n' "$GUM_MIN_VERSION" "$v" | sort -V -C; then
    echo "❌ Error: gum >= $GUM_MIN_VERSION required (found: $v)." >&2
    return 1
  fi
  return 0
}

# --- General -------------------------------------------

warn() {
  printf '⚠️  Warning: %s\n' "$*" >&2
}

truthy() {
	case "${1,,}" in
	1|true|y|yes)
		return 0
		;;
	esac
	return 1
}

# --- Clustered short options ----------------------------

# expand_clustered_options <out_array> <no_arg_opts> <arg_opts> [args...]
#
# Expands clustered short options in [args...] and stores the result
# in <out_array> (nameref).
#
#   <no_arg_opts>  string of short option letters that take no argument
#   <arg_opts>     string of short option letters that take an argument
#
# Examples:
#   "-rs"      -> -r -s
#   "-rfo out" -> -r -f -o out
#   "-rfoout"  -> -r -f -o out
expand_clustered_options() {
  local -n _eco_out="$1"; shift
  local no_arg="$1"; shift
  local arg_opt="$1"; shift

  local arg rest opt
  _eco_out=()

  for arg in "$@"; do
    if [[ "$arg" =~ ^-[a-zA-Z]{2,}$ ]]; then
      rest="${arg#-}"
      while [ -n "$rest" ]; do
        opt="${rest:0:1}"
        rest="${rest:1}"
        _eco_out+=("-${opt}")
        if [[ "$arg_opt" == *"$opt"* ]] && [ -n "$rest" ]; then
          _eco_out+=("$rest")
          rest=""
        fi
      done
    else
      _eco_out+=("$arg")
    fi
  done
}

# --- Debug functions -----------------------------------

chkFile() {
  [ -f "${1}" ]
}

section() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

safe_cat() {
  FILE="$1"

  if [ -r "$FILE" ]; then
    cat "$FILE" 2>&1
  elif [ -e "$FILE" ]; then
    echo "EXISTS BUT NOT READABLE: $FILE"
  else
    echo "MISSING: $FILE"
  fi
}

dump_files() {
  for FILE in "$@"; do
    echo
    echo "----- $FILE -----"
    safe_cat "$FILE"
  done
}

dump_existing_globs() {
  for FILE in "$@"; do
    [ -e "$FILE" ] || continue
    echo
    echo "----- $FILE -----"
    safe_cat "$FILE"
  done
}

lak_timer_start() {
  local name="${1:?timer_start: name required}"

  if [[ -n "${TIMER_START[$name]:-}" ]]; then
    echo "timer_start: timer '$name' is already running" >&2
    return 1
  fi
  # shellcheck disable=SC2004 # reason: false positive on associative array keys
  TIMER_START[$name]="$SECONDS"
}

# Returns the elapsed seconds for a running timer without stopping it
lak_timer_elapsed() {
  local name="${1:?timer_elapsed: name required}"

  if [[ -z "${TIMER_START[$name]:-}" ]]; then
    echo "timer_elapsed: no timer named '$name'" >&2
    return 1
  fi

  # shellcheck disable=SC2004 # reason: false positive on associative array keys
  echo $((SECONDS - TIMER_START[$name]))
}

# Stops the timer and returns the final elapsed seconds
lak_timer_stop() {
  local name="${1:?timer_stop: name required}"

  if [[ -z "${TIMER_START[$name]:-}" ]]; then
    echo "timer_stop: no timer named '$name'" >&2
    return 1
  fi
  # shellcheck disable=SC2004 # reason: false positive on associative array keys
  local elapsed=$((SECONDS - TIMER_START[$name]))
  unset 'TIMER_START[$name]'
  echo "$elapsed"
}

# --- Common checks -------------------------------------

check_boot_img() {
  "${KIT_DIR}/magictest.sh" "$@"
}

# check_dir <path> [description]
#   Checks if the given path points to a directory. Throws an error if the check fails.
#   If set, the description is used to provide a more specific error-message.
#   e.g. `check_dir /mnt/folder mount-path` --> throws:
#     "The mount-path must not be empty."
#			"The mount-path '/mnt/folder' is not a directory or does not exist." 
#   description defaults to "path"
check_dir() {
	local desc="${2:"path"}"
  if [ -z "${1:-}" ]; then
		echo "❌ Error: The ${desc} must not be empty." >&2
    exit 1
  fi
  if [ ! -d "${1}" ]; then
    echo "❌ Error: The ${desc} '${1}' is not a directory or does not exist." >&2
    exit 1
  fi
  return 0
}

# check_file <filepath> [description]
#   Checks if the given filepath points to a file. Throws an error if the check fails.
#   If set, the description is used to provide a more specific error-message.
#   e.g. `check_file /usr/.config configuration-filepath` --> throws:
#     "The configuration-filepath must not be empty."
#			"The configuration-filepath '/usr/.config' is not a file or does not exist." 
#   description defaults to "filepath"
check_file() {
	local desc="${2:"filepath"}"
  if [ -z "${1:-}" ]; then
		echo "❌ Error: The ${desc} must not be empty." >&2
    exit 1
  fi
  if [ ! -f "${1}" ]; then
    echo "❌ Error: The ${desc} '${1}' is not a file or does not exist." >&2
    exit 1
  fi
  return 0
}

# get_file_type <FILE> [MIME_TYPE]
#		Helper to call file --brief with --magic-file preset to a small internal magic file,
#   which contains the most common filetypes.
#   If MIME_TYPE is 1, true, y or yes the "--mime-type" flag will be passed,
#   which changes the output to the file's mime-type.
get_file_type() {
  local file="${1}"
  local magic="${KIT_DIR}/magic/common-slim.magic"
  local opt="--brief --magic-file ${magic}"
  if [ "$(truthy "${2}")" -eq 0 ]; then
    opt="--mime-type ${opt}"
  fi
  check_file "${file}"
  file "$opt" "$file"
}

# get_mime_type <FILE> [MIME_TYPE]
#   Returns a file's mime-type.
#		Helper to call file --brief --mime-type with --magic-file preset to
#   a small internal magic file, which contains the most common filetypes.
get_mime_type() {
  get_file_type "${1}" true
}

# print_cmd <args...>
#   Prints the arguments as a shell-pasteable command line.
#   Values are quoted with printf %q so the output can be
#   re-run verbatim, regardless of spaces or special chars.
print_cmd() {
	local arg
	for arg in "$@"; do
		printf '%q ' "$arg"
	done
	printf '\n'
}

# --- Project handling ----------------------------------

find_project_files() {
	local dir="$PWD"
  while [ "$dir" != "/" ] && [ -n "$dir" ]; do
    if [ -e "$dir/AndroidKernel.mk" ] && [ -e "$dir/Makefile" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir=$(dirname -- "$dir")
  done
  return 1
}

find_project_marker() {
  local dir="$PWD"
  while [ "$dir" != "/" ] && [ -n "$dir" ]; do
    if [ -e "$dir/.project" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir=$(dirname -- "$dir")
  done
  return 1
}

find_project_folder() {
	local dir
  if ! dir=$(find_project_marker); then
		if ! dir=$(find_project_files); then
			echo "❌ Error: It seems that you are not in an android kernel project-folder (no .project marker or Android-kernel make-files found)." >&2
			echo "👉 Please create an empty file called '.project', in the root folder of your android kernel project." >&2
			return 1
		fi
	fi
	printf '%s\n' "$dir"
	return 0
}

cd_project_root() {
  local root
  if ! root=$(find_project_folder); then
    echo "❌ Error: It seems that you are not in a project-folder (no .project marker found)." >&2
    echo "👉 Please create an empty file called '.project', in the root folder of your project." >&2
    return 1
  fi
  cd "$root" || return 1
}

# --- Log Handling (Private) ----------------------------

_log_rotate() {
  local dir="${KIT_COMMON_CFG_LOG_DIR:-$PWD/logs}"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -type f -name 'run-*.log' \
    -size +"${KIT_LOG_CFG_ROTATE_MAX_SIZE}c" -delete 2>/dev/null || true
  local -a files
  mapfile -t files < <(
    find "$dir" -maxdepth 1 -type f -name 'run-*.log' -printf '%T@ %p\n' 2>/dev/null \
      | sort -n | cut -d' ' -f2-
  )
  local n="${#files[@]}" i
  for ((i = 0; i < n - KIT_LOG_CFG_ROTATE_MAX_COUNT; i++)); do
    rm -f -- "${files[i]}"
  done
}

_log_write_header() {
  local script_name="$1"; shift
  {
    printf '\n'
    printf '===== %s | %s =====\n' \
      "$script_name" "$(date '+%Y-%m-%d %H:%M:%S')"
    if [ "$#" -gt 0 ]; then
      printf 'args:'
      printf ' %q' "$@"
      printf '\n'
    fi
    printf '\n'
  } >&3 2>/dev/null || true
}

_log_close() {
  if [ "${_LOG_INITIALIZED:-0}" -eq 1 ] && [ -e /dev/fd/3 ]; then
    {
      printf '\n===== %s – end: %s =====\n' \
        "$(basename -- "$0")" "$(date '+%Y-%m-%d %H:%M:%S')"
    } >&3 2>/dev/null || true
    exec 3>&- 2>/dev/null || true
  fi
  if [ "${_LOG_SESSION_OWNER:-0}" -eq 1 ]; then
    rm -f -- "$PWD/.log_session"
  fi
}

# --- Log Handling (Public) -----------------------------

# log_init <script-name> [args...]
#   Opens (or joins) the run log, installs a section header
#   and mirrors the script's stdout/stderr to the log via tee.
#   Must be called once, near the top of every script - ideally
#   right after cd_project_root.
log_init() {
  local script_name="${1:-$(basename -- "$0")}"
  shift || true

  [ "${_LOG_INITIALIZED:-0}" -eq 1 ] && return 0
  _LOG_INITIALIZED=1

  # Nested call: parent already set up the tee.
  if [ -n "${LAK_LOG_ACTIVE:-}" ] && [ -f "$LAK_LOG_ACTIVE" ]; then
    LOG_FILE="$LAK_LOG_ACTIVE"
    exec 3>>"$LOG_FILE" 2>/dev/null || true
    _log_write_header "$script_name" "$@"
    return 0
  fi

  # Fresh session.
  local logdir="${KIT_COMMON_CFG_LOG_DIR:-$PWD/logs}"
  local marker="$PWD/.log_session"
  local logfile=""

  if [ -f "$marker" ]; then
    logfile=$(<"$marker")
    if [ -n "$logfile" ] && [ -f "$logfile" ]; then
      local size
      size=$(stat -c %s -- "$logfile" 2>/dev/null || echo 0)
      if [ "$size" -gt "$KIT_LOG_CFG_ROTATE_MAX_SIZE" ]; then
        warn "Session log exceeded ${KIT_LOG_CFG_ROTATE_MAX_SIZE} bytes; starting a fresh log."
        logfile=""
      fi
    else
      logfile=""
    fi
  fi

  if [ -z "$logfile" ]; then
    if ! mkdir -p "$logdir" 2>/dev/null; then
      warn "Cannot create log directory: $logdir; logging disabled."
      return 0
    fi
    _log_rotate
    logfile="${logdir}/run-$(date +%Y-%m-%d_%H-%M-%S).log"
    printf '%s\n' "$logfile" > "$marker"
    _LOG_SESSION_OWNER=1
    trap '_log_close' EXIT INT TERM HUP
  fi

  LOG_FILE="$logfile"
  exec 3>>"$LOG_FILE" 2>/dev/null || true
  export LAK_LOG_ACTIVE="$LOG_FILE"

  exec > >(tee -a /dev/fd/3)
  exec 2>&1

  _log_write_header "$script_name" "$@"
}

# run_tool <command...>
#   Runs an external tool. Output always goes to the log;
#   on the terminal it appears only when VERBOSE=1.
run_tool() {
  if [ "${VERBOSE:-0}" -eq 1 ]; then
    "$@"
  elif [ -e /dev/fd/3 ]; then
    "$@" >&3 2>&1
  else
    "$@" >/dev/null 2>&1
  fi
}

# log_path
#   Prints the active log file path (empty if none).
log_path() {
  printf '%s\n' "${LOG_FILE:-}"
}

# --- Toolchain handling --------------------------------

# Toolchain state — survives re-sourcing in kit-invoked children.
# Only initialize if the environment did not already provide a value.
# DO not use this value to determinate which toolchain to use
if [ -z "${active_toolchain+set}" ]; then
  export active_toolchain=""
fi

load_toolchain() {
  local name="${KIT_COMMON_CFG_TOOLCHAIN:-default}"

	# No need to load a toolchain twice
	if [ "$active_toolchain" = "${name}" ]; then
		return 0
	fi

  local file="$KIT_DIR/toolchains/$name.sh"
  if [ ! -f "$file" ]; then
    echo "❌ Unknown toolchain: '$name'" >&2
    echo "   Available:" >&2
    for f in "$KIT_DIR"/toolchains/*.sh; do
      echo "     - $(basename "$f" .sh)" >&2
    done
    return 1
  fi

	active_toolchain="${name}"

  # shellcheck source=/dev/null
  source "$file"

	# Update directories that depend on the toolchain
	BUILD_DIR="$PWD/arch/${ARCH}/boot"

	return 0
}

# show_toolchain_env <VARNAME> [VARNAME...]
#   Prints "  VAR=value" for each name. Skips names that are
#   unset or empty, so toolchains can pass an over-complete list.
show_toolchain_env() {
  echo "Using toolchain:"
  local name value
  for name in "$@"; do
    value="${!name-}"
    [ -n "$value" ] && printf '  %s=%s\n' "$name" "$value"
  done
}

# --- ADB helpers ----------------------------------------

# Returns 0 if a device is reachable or in recovery state,
# 1 otherwise (adb missing, device unreachable, root not obtainable).
is_adb_reachable() {
	case "$1" in
	device|recovery) return 0 ;;
	*)              return 1 ;;
	esac
}

# Wait until an ADB device is connected and reachable.
#
# Polls `adb get-state` every ${KIT_COMMON_CFG_ADB_WAIT_INTERVAL} seconds (default 2)
# until the device reports the "device" state (i.e. it is connected,
# authorized and reachable). Other states such as "offline",
# "unauthorized", "bootloader" or "recovery" are ignored.
#
# Once connected, the function checks whether adbd is running as
# root (uid 0). If not, it attempts to restart adbd as root via
# `adb root` and waits for the device to come back.
#
# Environment:
#   KIT_COMMON_CFG_ADB_WAIT_INTERVAL   Poll interval in seconds (default: 2)
#   ADB_SILENT          If set to 1, only errors are printed (default: 0)
#
# Returns 0 if a reachable device with root adbd is available,
# 1 otherwise (adb missing, device unreachable, root not obtainable).
wait_for_adb() {
	local interval="${KIT_COMMON_CFG_ADB_WAIT_INTERVAL:-2}"
	local silent="${ADB_SILENT:-0}"
	local state uid

	if ! command -v adb >/dev/null 2>&1; then
		echo "❌ Error: 'adb' not found in PATH." >&2
		return 1
	fi

	# Wait for a reachable device (state == "device" or "recovery").
	if ! state=$(adb get-state 2>/dev/null) || ! is_adb_reachable "${state}"; then
		[ "${silent}" -eq 1 ] || echo "⏳ Waiting for ADB device (checking every ${interval}s) ..."
		until state=$(adb get-state 2>/dev/null) && is_adb_reachable "${state}"; do
			sleep "${interval}"
		done
	fi

	[ "${silent}" -eq 1 ] || echo "📡 ADB device connected (state: ${state})."

	# Check whether adbd is already running as root.
	uid=$(adb shell id -u 2>/dev/null | tr -d '\r')
	if [ "${uid}" = "0" ]; then
		[ "${silent}" -eq 1 ] || echo "🔓 ADB is running as root."
		return 0
	fi

	# In recovery, `adb root` usually fails or kills the connection.
	if [ "${state}" = "recovery" ]; then
		echo "❌ Error: adbd in recovery is not running as root (uid=${uid:-unknown})." >&2
		return 1
	fi

	# Attempt to switch adbd to root (normal device mode).
	[ "${silent}" -eq 1 ] || echo "🔒 ADB is not running as root; requesting root via 'adb root' ..."
	if ! adb root >/dev/null 2>&1; then
		echo "❌ Error: Failed to switch adbd to root (device may not support it)." >&2
		return 1
	fi

	# adbd restarts; wait for it to come back, then verify.
	adb wait-for-device >/dev/null 2>&1
	uid=$(adb shell id -u 2>/dev/null | tr -d '\r')
	if [ "${uid}" = "0" ]; then
		[ "${silent}" -eq 1 ] || echo "🔓 ADB is now running as root."
		return 0
	fi

	echo "❌ Error: adbd is still not running as root after 'adb root'." >&2
	return 1
}

# ========================================================
# --- Pipeline progress ----------------------------------
# ========================================================
#
# Rendering respects KIT_SILENT=1 (exported by whichever script saw
# -s first). State tracking is unaffected: powerline_emit always
# updates KIT_PIPELINE_STATE, only the display is suppressed.
#
# Optional one-line progress indicator for multi-step kit chains
# (clean-it → build-it → pack-it → flash-it). Driven by the exported
# KIT_PIPELINE_STATE variable. Only producer scripts (build-it,
# pack-it) call powerline_emit; consumer scripts stay untouched.
#
# Rendered on stderr so stdout pipes stay clean. Always terminates
# with an ANSI reset to avoid leaking colour into following output.
#
# Visuals (glyph + 256-colour codes) are tunable via the KIT_PIPELINE_*
# shell variables; they are intentionally not part of the config schema.

: "${KIT_PIPELINE_GLYPH:=$'\ue0b0'}"
: "${KIT_PIPELINE_FG:=16}"
: "${KIT_PIPELINE_ACTIVE:=34}"
: "${KIT_PIPELINE_DONE_A:=240}"
: "${KIT_PIPELINE_DONE_B:=237}"
: "${KIT_PIPELINE_PENDING_A:=248}"
: "${KIT_PIPELINE_PENDING_B:=245}"

# powerline_available
#   Returns 0 if KIT_PIPELINE_STATE is set and non-empty.
#   Colour-vs-ASCII is decided later, in powerline_render.
powerline_available() {
  [ -n "${KIT_PIPELINE_STATE:-}" ]
}

# _powerline_bg <index> <state>
#   Prints the background colour code for a segment. Adjacent segments
#   in the same category alternate between two shades, keyed off the
#   segment's absolute index, so two greys never sit next to each other.
_powerline_bg() {
  local idx="$1" state="$2"
  case "$state" in
    active)  printf '%s' "$KIT_PIPELINE_ACTIVE" ;;
    done)    if [ $((idx % 2)) -eq 0 ]; then printf '%s' "$KIT_PIPELINE_DONE_A";
             else                            printf '%s' "$KIT_PIPELINE_DONE_B"; fi ;;
    *)       if [ $((idx % 2)) -eq 0 ]; then printf '%s' "$KIT_PIPELINE_PENDING_A";
             else                            printf '%s' "$KIT_PIPELINE_PENDING_B"; fi ;;
  esac
}

# powerline_render
#   Emits the pipeline line for the current KIT_PIPELINE_STATE.
#   NerdFont glyph + 256-colour if KIT_COMMON_CFG_NERDFONT=1, plain
#   ASCII arrows otherwise (active step gets a '*' suffix).
powerline_render() {
  powerline_available || return 0
	[ "${KIT_SILENT:-0}" = "1" ] && return 0

  local -a entries
  IFS=',' read -ra entries <<<"${KIT_PIPELINE_STATE}"
  local n="${#entries[@]}"
  [ "$n" -gt 0 ] || return 0

  # --- ASCII fallback ---
  if [ "${KIT_COMMON_CFG_NERDFONT:-0}" != "1" ]; then
    local i entry label state out=""
    for ((i = 0; i < n; i++)); do
      entry="${entries[i]}"
      label="${entry%%=*}"
      state="${entry#*=}"
      [ "$state" = "active" ] && label+="*"
      [ "$i" -gt 0 ] && out+=" -> "
      out+="${label}"
    done
    printf '%s\n' "$out" >&2
    return 0
  fi

  # --- NerdFont rendering ---
  local i entry label state bg prev_bg=""
  for ((i = 0; i < n; i++)); do
    entry="${entries[i]}"
    label="${entry%%=*}"
    state="${entry#*=}"
    bg="$(_powerline_bg "$i" "$state")"

    # Separator: fg = previous bg, bg = next bg, glyph fills the gap.
    if [ -n "$prev_bg" ]; then
      printf '\033[38;5;%sm\033[48;5;%sm%s' \
        "$prev_bg" "$bg" "$KIT_PIPELINE_GLYPH" >&2
    fi

    # Segment content.
    printf '\033[38;5;%sm\033[48;5;%sm %s ' \
      "$KIT_PIPELINE_FG" "$bg" "$label" >&2

    prev_bg="$bg"
  done

  # Trailing separator back to the default background.
  printf '\033[38;5;%sm\033[49m%s\033[0m\n' \
    "$prev_bg" "$KIT_PIPELINE_GLYPH" >&2
}

# powerline_emit <step-name>
#   Rewrites KIT_PIPELINE_STATE so that everything before <step-name>
#   is done, <step-name> is active, everything after is pending.
#   Exports the new state and re-renders.
#   No-op if the state variable is unset or <step-name> is unknown.
powerline_emit() {
  powerline_available || return 0
  local target="$1"
  [ -n "$target" ] || return 0

  local -a entries
  IFS=',' read -ra entries <<<"${KIT_PIPELINE_STATE}"

  # Verify the step exists before mutating anything.
  local entry found=0
  for entry in "${entries[@]}"; do
    [ "${entry%%=*}" = "$target" ] && { found=1; break; }
  done
  [ "$found" -eq 1 ] || return 0

  local i label state new="" seen=0
  for ((i = 0; i < ${#entries[@]}; i++)); do
    entry="${entries[i]}"
    label="${entry%%=*}"
    state="${entry#*=}"

    if [ "$label" = "$target" ]; then
      state="active"
      seen=1
    elif [ "$seen" -eq 0 ]; then
      state="done"
    else
      state="pending"
    fi

    [ -n "$new" ] && new+=","
    new+="${label}=${state}"
  done

  KIT_PIPELINE_STATE="$new"
  export KIT_PIPELINE_STATE
  powerline_render
}

# ========================================================
# --- Config registry ------------------------------------
# ========================================================

declare -gA _CFG_TYPE
declare -gA _CFG_GROUP
declare -gA _CFG_SCOPE
declare -gA _CFG_DEFAULT
declare -gA _CFG_DESC
declare -gA _CFG_HIDDEN
declare -gA _CFG_OPTIONS
declare -gA _CFG_OPTIONS_DIR
declare -gA _CFG_MIN
declare -gA _CFG_MAX
declare -gA _CFG_CHECK
declare -gA _CFG_PLACEHOLDER

declare -g _CFG_LOADED=0

# config_declare <VAR> <type> [flags...]
#   Registers a configurable variable. See config-schema.sh for usage.
#   Flags:
#     --group DOMAIN
#     --scope global|project|both
#     --default VALUE
#     --desc TEXT
#     --options "opt1 opt2 ..."        (enum)
#     --options-from-dir PATH          (enum, resolved at render time)
#     --min N  --max N                 (int)
#     --placeholder TEXT               (string)
#     --check                          (file/dir: validate existence)
#     --hidden                         (excluded from config-it menus)
config_declare() {
  local var="${1:-}" type="${2:-}"; shift 2 || true
  if [ -z "$var" ] || [ -z "$type" ]; then
    echo "❌ config_declare: <VAR> <type> required." >&2
    return 1
  fi
  [[ "$var" == KIT_* ]] || { echo "❌ config_declare: '$var' must start with KIT_." >&2; return 1; }
  [[ "$var" =~ ^KIT_[A-Z0-9_]+$ ]] || { echo "❌ config_declare: invalid name '$var'." >&2; return 1; }
  case "$type" in
    bool|enum|int|string|file|dir) ;;
    *) echo "❌ config_declare $var: unknown type '$type'." >&2; return 1 ;;
  esac

  local group="" scope="" default="" desc="" hidden=0
  local options="" options_dir="" min="" max="" check=0 placeholder=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --group)           group="$2"; shift 2 ;;
      --scope)           scope="$2"; shift 2 ;;
      --default)         default="$2"; shift 2 ;;
      --desc)            desc="$2"; shift 2 ;;
      --options)         options="$2"; shift 2 ;;
      --options-from-dir) options_dir="$2"; shift 2 ;;
      --min)             min="$2"; shift 2 ;;
      --max)             max="$2"; shift 2 ;;
      --placeholder)     placeholder="$2"; shift 2 ;;
      --hidden)          hidden=1; shift ;;
      --check)           check=1; shift ;;
      *) echo "❌ config_declare $var: unknown flag '$1'." >&2; return 1 ;;
    esac
  done

  case "$scope" in
    global|project|both) ;;
    *) echo "❌ config_declare $var: invalid scope '$scope'." >&2; return 1 ;;
  esac

  _CFG_TYPE["$var"]="$type"
  _CFG_GROUP["$var"]="$group"
  _CFG_SCOPE["$var"]="$scope"
  _CFG_DEFAULT["$var"]="$default"
  _CFG_DESC["$var"]="$desc"
  _CFG_HIDDEN["$var"]="$hidden"
  _CFG_OPTIONS["$var"]="$options"
  _CFG_OPTIONS_DIR["$var"]="$options_dir"
  _CFG_MIN["$var"]="$min"
  _CFG_MAX["$var"]="$max"
  _CFG_CHECK["$var"]="$check"
  _CFG_PLACEHOLDER["$var"]="$placeholder"
}

# ========================================================
# --- Config loading -------------------------------------
# ========================================================

# _cfg_read_value <file> <var>
#   Print the raw value of <var> from <file>, or nothing if absent.
_cfg_read_value() {
  local file="$1" var="$2"
  [ -f "$file" ] || return 0
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    if [[ "$line" =~ ^[[:space:]]*${var}=(.*)$ ]]; then
      local v="${BASH_REMATCH[1]}"
      if   [[ "$v" == \"*\" ]]; then v="${v#\"}"; v="${v%\"}"
      elif [[ "$v" == \'*\' ]]; then v="${v#\'}"; v="${v%\'}"; fi
      printf '%s' "$v"
      return 0
    fi
  done < "$file"
}

# config_inherited_value <var>
#   Value the variable would have without the project .kit override.
#   Resolution: schema default → global .kit → environment.
config_inherited_value() {
  local var="$1"
  [ -n "${_CFG_TYPE[$var]+set}" ] || {
    echo "❌ config_inherited_value: unknown var '$var'." >&2
    return 1
  }

  local value="${_CFG_DEFAULT[$var]}"

  local global_file="${KIT_DIR}/.kit"
  if [ -f "$global_file" ]; then
    local v; v="$(_cfg_read_value "$global_file" "$var")"
    [ -n "$v" ] && value="$v"
  fi

  if [ -n "${_CFG_ENV_SNAPSHOT[$var]+set}" ]; then
    value="${_CFG_ENV_SNAPSHOT[$var]}"
  fi

  printf '%s\n' "$value"
}

# _cfg_scope_accepts <filter> <scope>
#   True if a variable with the given scope may be set by a file
#   of the given kind ("global" or "project").
_cfg_scope_accepts() {
  case "${1}:${2}" in
    global:global|global:both|project:project|project:both) return 0 ;;
  esac
  return 1
}

# _cfg_apply_file <file> <filter>
#   Line-by-line parse of a .kit file. Only KIT_* assignments whose
#   scope matches <filter> are honoured.
_cfg_apply_file() {
  local file="$1" filter="$2"
  local line var val n=0 scope
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in ''|'#'*) continue ;; esac

    if [[ "$line" =~ ^[[:space:]]*(KIT_[A-Z0-9_]+)=(.*)$ ]]; then
      var="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"

      if [ -z "${_CFG_TYPE[$var]+set}" ]; then
        warn "config $file:$n: unknown variable '$var'; ignored."
        continue
      fi

      scope="${_CFG_SCOPE[$var]}"
      if ! _cfg_scope_accepts "$filter" "$scope"; then
        # Silent: this file simply has no business with this var.
        continue
      fi

      # Strip one matching pair of surrounding quotes.
      if [[ "$val" == \"*\" ]]; then
        val="${val#\"}"; val="${val%\"}"
      elif [[ "$val" == \'*\' ]]; then
        val="${val#\'}"; val="${val%\'}"
      fi

      printf -v "$var" '%s' "$val"
      export "${var?}"
    else
      warn "config $file:$n: not a KIT_* assignment; ignored."
    fi
  done < "$file"
}

# _cfg_project_root
#   Prints the project root that owns the effective project .kit,
#   or nothing if we are not inside a project.
_cfg_project_root() {
  find_project_marker 2>/dev/null || find_project_files 2>/dev/null || true
}

declare -gA _CFG_ENV_SNAPSHOT

# config_load
#   Resolve the effective value of every declared KIT_* variable.
#   Precedence (low → high):
#     1. schema default
#     2. $KIT_DIR/.kit       (global, applies scope=global + both)
#     3. <project>/.kit      (applies scope=project + both)
#     4. environment         (any KIT_* already set in the caller's env)
#   Idempotent.
config_load() {
  [ "$_CFG_LOADED" -eq 1 ] && return 0

  local var

  # 1. Snapshot environment overrides before anything touches them.
  _CFG_ENV_SNAPSHOT=()
  for var in "${!_CFG_TYPE[@]}"; do
    if [ "${!var+set}" = "set" ]; then
      _CFG_ENV_SNAPSHOT["$var"]="${!var}"
    fi
  done

  # 2. Schema defaults.
  for var in "${!_CFG_TYPE[@]}"; do
    printf -v "$var" '%s' "${_CFG_DEFAULT[$var]}"
  done

  # 3. Global file.
  local global_file="${KIT_DIR}/.kit"
  [ -f "$global_file" ] && _cfg_apply_file "$global_file" global

  # 4. Project file.
  local proj_root proj_file
  proj_root="$(_cfg_project_root)"
  if [ -n "$proj_root" ]; then
    proj_file="${proj_root}/.kit"
    [ -f "$proj_file" ] && _cfg_apply_file "$proj_file" project
  fi

  # 5. Environment has the highest precedence.
  for var in "${!_CFG_ENV_SNAPSHOT[@]}"; do
    printf -v "$var" '%s' "${_CFG_ENV_SNAPSHOT[$var]}"
    export "${var?}"
  done

  _CFG_LOADED=1
  return 0
}

# ========================================================
# --- Config writing -------------------------------------
# ========================================================

# _cfg_target_file <scope>
#   Prints the .kit path a var of the given scope should be written to.
_cfg_target_file() {
  case "$1" in
    global)  printf '%s\n' "${KIT_DIR}/.kit" ;;
    project) printf '%s\n' "$(_cfg_project_root)/.kit" ;;
    both)    printf '%s\n' "$(_cfg_project_root)/.kit" ;;  # project wins
  esac
}

# _kit_file_remove <file> <var>
#   Delete the assignment line for <var>. The file itself is kept,
#   even if it becomes empty (comments or the state section may
#   still live there).
_kit_file_remove() {
  local file="$1" var="$2"
  [ -f "$file" ] || return 0

  local tmp; tmp="$(mktemp "${file}.XXXXXX")" || return 1
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^[[:space:]]*${var}= ]]; then
      continue
    fi
    printf '%s\n' "$line" >>"$tmp"
  done <"$file"
  mv -- "$tmp" "$file"
}

# _kit_file_rewrite <file> <VAR> <value>
#   Atomically rewrite <file> so that <VAR> is set to <value>.
#   STATE vars land below the state marker; others above.
_kit_file_rewrite() {
  local file="$1" var="$2" value="$3"
  local is_state=0
	[[ "$var" =~ ^KIT_[A-Z0-9_]+_STATE_[A-Z0-9_]+$ ]] && is_state=1

  local dir; dir="$(dirname -- "$file")"
  mkdir -p -- "$dir" || return 1

  local tmp; tmp="$(mktemp "${file}.XXXXXX")" || return 1

  # Pass 1: does the variable already exist in the file?
  local found=0 line
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" =~ ^[[:space:]]*${var}= ]]; then
        found=1
        break
      fi
    done < "$file"
  fi

  # Pass 2: copy the file, replacing the variable's line when hit.
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" =~ ^[[:space:]]*${var}= ]]; then
        printf '%s="%s"\n' "$var" "${value//\"/\\\"}" >>"$tmp"
      else
        printf '%s\n' "$line" >>"$tmp"
      fi
    done < "$file"
  fi

  # If the variable was not in the file, append it now.
  if [ "$found" -eq 0 ]; then
    if [ "$is_state" -eq 1 ]; then
      if ! grep -q '^# --- state' "$tmp" 2>/dev/null; then
        printf '\n# --- state (managed automatically; do not edit) ---\n' >>"$tmp"
      fi
      printf '%s="%s"\n' "$var" "${value//\"/\\\"}" >>"$tmp"
    else
      printf '%s="%s"\n' "$var" "${value//\"/\\\"}" >>"$tmp"
    fi
  fi

  mv -- "$tmp" "$file"
}

# config_write <VAR> <value> [<target_file>]
#   Persist a value into the appropriate .kit file and update the
#   in-memory variable. Creates parent directories if needed.
#
#   Without <target_file>, the destination is derived from the
#   variable's scope (global → $KIT_DIR/.kit, project/both →
#   <project>/.kit). With <target_file>, that file is used
#   instead — config-it.sh uses this to honor the edit target
#   selected by the user, regardless of the variable's scope.
config_write() {
  local var="$1" value="${2-}" target="${3:-}"
  [ -n "${_CFG_TYPE[$var]+set}" ] || {
    echo "❌ config_write: unknown var '$var'." >&2
    return 1
  }

  local scope="${_CFG_SCOPE[$var]}"
  local file
  if [ -n "$target" ]; then
    file="$target"
  else
    file="$(_cfg_target_file "$scope")"
  fi
  [ -n "$file" ] || {
    echo "❌ config_write: no target file for $var." >&2
    return 1
  }

  # Delta pruning: project-overridable vars whose new value equals the
  # inherited value are removed from the project .kit instead of being
  # written. Keeps the project file minimal.
  if [ "$scope" = "project" ] || [ "$scope" = "both" ]; then
    if [ "$value" = "$(config_inherited_value "$var")" ]; then
      _kit_file_remove "$file" "$var"
      printf -v "$var" '%s' "$value"
      export "${var?}"
      return 0
    fi
  fi

  _kit_file_rewrite "$file" "$var" "$value" || return 1
  printf -v "$var" '%s' "$value"
  export "${var?}"
  return 0
}

# config_state_get <VAR>
config_state_get() {
  local var="$1"
  [ -n "${_CFG_TYPE[$var]+set}" ] || return 1
  printf '%s\n' "${!var:-}"
}

# config_state_set <VAR> <value>
config_state_set() {
  local var="$1" value="$2"
  [[ "$var" =~ ^KIT_[A-Z0-9_]+_STATE_[A-Z0-9_]+$ ]] || {
    echo "❌ config_state_set: not a state variable: $var" >&2
    return 1
  }

  # Target file derives from the variable's declared scope so that
  # global-scope STATE vars (KIT_COMMON_STATE_*) land in $KIT_DIR/.kit
  # instead of the project file.
  local scope="${_CFG_SCOPE[$var]:-project}"
  local file; file="$(_cfg_target_file "$scope")"
  [ -n "$file" ] || {
    echo "❌ config_state_set: no target file for $var." >&2
    return 1
  }

  _kit_file_rewrite "$file" "$var" "$value" || return 1
  printf -v "$var" '%s' "$value"
  export "${var?}"
  printf '%s\n' "$value"
}

# ========================================================
# --- Config introspection (for config-it) ---------------
# ========================================================

# config_list_vars [<group>] [--include-hidden]
#   Prints declared variable names, one per line.
config_list_vars() {
  local group="" include_hidden=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --include-hidden) include_hidden=1; shift ;;
      *) group="$1"; shift ;;
    esac
  done
  local var
  for var in "${!_CFG_TYPE[@]}"; do
    [ "$include_hidden" -eq 0 ] && [ "${_CFG_HIDDEN[$var]}" = "1" ] && continue
    [ -n "$group" ] && [ "${_CFG_GROUP[$var]}" != "$group" ] && continue
    printf '%s\n' "$var"
  done
}

# config_list_groups
#   Prints all groups that have at least one visible variable.
config_list_groups() {
  local var group seen=""
  for var in "${!_CFG_TYPE[@]}"; do
    [ "${_CFG_HIDDEN[$var]}" = "1" ] && continue
    group="${_CFG_GROUP[$var]}"
    [ -z "$group" ] && continue
    case " $seen " in *" $group "*) continue ;; esac
    seen="$seen $group"
    printf '%s\n' "$group"
  done
}

# config_meta <VAR> <field>
#   Prints one metadata field: type|group|scope|default|desc|hidden|
#   options|options_dir|min|max|check|placeholder
config_meta() {
  local var="$1" field="$2"
  case "$field" in
    type)        printf '%s\n' "${_CFG_TYPE[$var]:-}" ;;
    group)       printf '%s\n' "${_CFG_GROUP[$var]:-}" ;;
    scope)       printf '%s\n' "${_CFG_SCOPE[$var]:-}" ;;
    default)     printf '%s\n' "${_CFG_DEFAULT[$var]:-}" ;;
    desc)        printf '%s\n' "${_CFG_DESC[$var]:-}" ;;
    hidden)      printf '%s\n' "${_CFG_HIDDEN[$var]:-0}" ;;
    options)     printf '%s\n' "${_CFG_OPTIONS[$var]:-}" ;;
    options_dir) printf '%s\n' "${_CFG_OPTIONS_DIR[$var]:-}" ;;
    min)         printf '%s\n' "${_CFG_MIN[$var]:-}" ;;
    max)         printf '%s\n' "${_CFG_MAX[$var]:-}" ;;
    check)       printf '%s\n' "${_CFG_CHECK[$var]:-0}" ;;
    placeholder) printf '%s\n' "${_CFG_PLACEHOLDER[$var]:-}" ;;
    value)       printf '%s\n' "${!var:-}" ;;
    *) echo "❌ config_meta: unknown field '$field'." >&2; return 1 ;;
  esac
}

# --- Schema (declarations) ------------------------------

# shellcheck source=/dev/null
source "${KIT_DIR}/config-schema.sh"