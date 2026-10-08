#!/usr/bin/env bash
# ========================================================
# Android Kernel Kit
#
# Performs magic-byte checks on an file and returns the
# passed type or an error, if all check fails.
# Tries to check "boot.img" if no file is provided.
# ========================================================
#

# --- Help -----------------------------------------------

usage() {
  cat <<'EOF'
magictest.sh - Performs magic-byte checks on a file.

USAGE
    magictest.sh [OPTIONS] <PATH>

DESCRIPTION
    Performs magic-byte checks on a file and returns the
    passed type or an error, if all check fails.
    Tries to check "boot.img" if no file is provided.

ARGUMENTS
    PATH        Path to the image file to test.

OPTIONS
    -m, --magic-file MAGIC
        Magic-file with byte-checks to perform.
        Default: android boot image byte-checks.

    -h, --help
        Show this help and exit.

    -s, --silent
        Same magic, but without the usage of words.

    -t, --type
        Type-string that is used for error-messages.

EXAMPLES
    magictest.sh boot.img
        Performs the default byte-checks on boot.img.

    magictest.sh --magic my.magic boot.img
        Performs the byte-checks that are defined in my.magic, against boot.img.

EXIT STATUS
    0   pass
    1   error (invalid arguments, file not found, not a boot image)
EOF
}

# --- Common helpers -------------------------------------

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/common.sh"

# --- Defaults -------------------------------------------

file_type="type"
is_boot=1
magic_file="${KIT_DIR}/magic/bootimage.magic"
target_file="boot.img"
target_file_set=0
silence=0

# --- Argument parsing -----------------------------------

while [ $# -gt 0 ]; do
  case "${1}" in
  -h | --help)
    usage
    exit 0
    ;;
  -m | --magic-file)
    if [ -z "${2:-}" ]; then
      echo "❌ Error: $1 requires a path to the magic-file." >&2
      exit 1
    fi
    magic_file="${2}"
    is_boot=0
    shift 2
    ;;
  -s | --silent)
    silence=1
    shift
    ;;
  -t | --type)
    if [ -z "${2:-}" ]; then
      echo "❌ Error: $1 requires a type string for error messages." >&2
      exit 1
    fi
    file_type="${2}"
    is_boot=0
    shift 2
    ;;
  --)
    shift
    break
    ;; # explicit end of options
  -*)
    echo "❌ Unknown option: $1" >&2
    exit 1
    ;;
  *)
    target_file="${1}"
    target_file_set=1
    shift
    ;;
  esac
done

# Anything after "--" is a positional argument. At most one is allowed.
if [ $# -gt 0 ]; then
  if [ "$target_file_set" -eq 1 ]; then
    echo "❌ Too many arguments: '$target_file' and '$1'" >&2
    exit 1
  fi
  target_file="$1"
  target_file_set=1
  shift
fi

if [ $# -gt 0 ]; then
  echo "❌ Unexpected arguments: $*" >&2
  exit 1
fi

# --- Preflight checks -----------------------------------

if [ $is_boot -eq 1 ]; then
  file_type="android boot image type"
fi

check_file "${target_file}"
check_file "${magic_file}"

# --- Run ------------------------------------------------
mime=$(file -b --mime-type --magic-file "$magic_file" "$target_file" 2>/dev/null)
if [ "$mime" != "application/x-androidkit" ]; then
  echo "❌ Error: It seems that '${target_file}' is not a known ${file_type}." >&2
  exit 1
fi

isboot=$(file --magic-file "$magic_file" "$target_file" 2>/dev/null)
[ "$silence" -eq 0 ] && echo "✅ Validated (detected: ${isboot})"
exit 0
