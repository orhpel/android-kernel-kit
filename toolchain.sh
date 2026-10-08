#!/usr/bin/env bash
# ========================================================
# Android Kernel Kit
#
# toolchain.sh
# Inspect or change the toolchain selected for the
# current project.
#
# The selection is stored as KIT_COMMON_CFG_TOOLCHAIN in the
# project's .kit file and read by load_toolchain() at build time.
# This script is a convenience wrapper around that setting.
# ========================================================

# --- Help -----------------------------------------------

usage() {
  cat <<'EOF'
toolchain.sh - inspect or change the toolchain of the current project

USAGE
    toolchain.sh [OPTIONS] [NAME]

DESCRIPTION
    Manage the toolchain selection for the current project. The
    value is stored as KIT_COMMON_CFG_TOOLCHAIN in the project's
    .kit file and read by load_toolchain() at build time.

    Without arguments, the current selection and the list of
    available toolchains are shown.

ARGUMENTS
    NAME    Name of the toolchain to select. Must match a file in
            <KIT_DIR>/toolchains/<NAME>.sh. The special value
            "default" is a regular choice: load_toolchain() also
            falls back to it when no explicit selection is made.

OPTIONS
    -m, --menu
        Show an interactive picker with arrow-key navigation.

    -u, --unset
        Remove any project-level override. The project falls back
        to whatever the inherited value is (schema default or a
        global selection).

    -h, --help
        Show this help and exit.

EXAMPLES
    toolchain.sh
        Show the current selection and the list of toolchains.

    toolchain.sh toolchain-arm4.9
        Select the toolchain named "toolchain-arm4.9".

    toolchain.sh --menu
        Pick a toolchain interactively.

    toolchain.sh --unset
        Clear the project-level override.
EOF
}

# --- Common kit -----------------------------------------

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/common.sh"
source "${KIT_DIR}/menu.sh"

# --help must work outside a project too.
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

cd_project_root || exit 1

# Resolve kit configuration.
config_load

# --- Configuration --------------------------------------

TOOLCHAIN_DIR="${KIT_DIR}/toolchains"

if [ ! -d "$TOOLCHAIN_DIR" ]; then
  echo "❌ Error: toolchain directory not found: $TOOLCHAIN_DIR" >&2
  exit 1
fi

# Effective selection after config_load: schema default, global .kit and
# project .kit have already been merged. This is what load_toolchain()
# will see at build time.
CURRENT="${KIT_COMMON_CFG_TOOLCHAIN:-default}"

# Populate the list of available toolchains.
TOOLCHAINS=()
for f in "$TOOLCHAIN_DIR"/*.sh; do
  [ -f "$f" ] || continue
  TOOLCHAINS+=("$(basename "$f" .sh)")
done

if [ "${#TOOLCHAINS[@]}" -eq 0 ]; then
  echo "❌ Error: no toolchains found in $TOOLCHAIN_DIR" >&2
  exit 1
fi

# --- Helper functions -----------------------------------

toolchain_exists() {
  [ -f "$TOOLCHAIN_DIR/$1.sh" ]
}

show_status() {
  echo "🔧 Toolchain for $PWD"
  echo "   Current:   $CURRENT"
  echo

  if ! toolchain_exists "$CURRENT"; then
    echo "⚠️  '$CURRENT' is configured but no longer available." >&2
    echo "   Run 'toolchain.sh --unset' or pick a new one." >&2
    echo
  fi

  if ! toolchain_exists default; then
    echo "⚠️  No 'default' toolchain found in $TOOLCHAIN_DIR." >&2
    echo "   Projects without an explicit selection will fail to build." >&2
    echo
  fi

  echo "   Available:"
  local t marker
  for t in "${TOOLCHAINS[@]}"; do
    if [ "$t" = "$CURRENT" ]; then
      marker="*"
    else
      marker=" "
    fi
    printf '     [%s] %s\n' "$marker" "$t"
  done
}

set_toolchain() {
  local name="$1"

  if ! toolchain_exists "$name"; then
    echo "❌ Unknown toolchain: '$name'" >&2
    echo "   Available:" >&2
    local t
    for t in "${TOOLCHAINS[@]}"; do
      echo "     - $t" >&2
    done
    return 1
  fi

  if [ "$name" = "$CURRENT" ]; then
    echo "ℹ️  '$name' is already the current toolchain."
    return 0
  fi

  # Delta pruning in config_write drops the project override when it
  # matches the inherited value.
  config_write KIT_COMMON_CFG_TOOLCHAIN "$name" >/dev/null
  echo "✅ Toolchain set to '$name'."
}

unset_toolchain() {
  # "Unset" means: forget any project-level choice. We compute the
  # inherited value and write it back; delta pruning removes the
  # project entry if the two match.
  local inherited
  inherited="$(config_inherited_value KIT_COMMON_CFG_TOOLCHAIN)"

  if [ "$CURRENT" = "$inherited" ]; then
    echo "ℹ️  No project-level toolchain override is set."
    return 0
  fi

  config_write KIT_COMMON_CFG_TOOLCHAIN "$inherited" >/dev/null
  echo "🧹 Cleared project toolchain override (now using '$inherited')."
}

# --- Menu -----------------------------------------------

define_toolchain_menu() {
  local t desc

  menu_begin "🔧 Select a toolchain  (project: $PWD)"

  for t in "${TOOLCHAINS[@]}"; do
    desc=""
    [ "$t" = "$CURRENT" ] && desc="currently active"

    menu_action "$t" \
      "config_write KIT_COMMON_CFG_TOOLCHAIN '$t' >/dev/null && echo '✅ Toolchain set to '\''$t'\''.'" \
      --desc "$desc" --close
  done

  menu_end toolchain_menu
}

# --- Argument parsing -----------------------------------

ACTION=""
TARGET_NAME=""

while [ $# -gt 0 ]; do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  -m | --menu)
    [ -n "$ACTION" ] && {
      echo "❌ Error: multiple actions specified." >&2
      exit 1
    }
    ACTION="menu"
    shift
    ;;
  -u | --unset)
    [ -n "$ACTION" ] && {
      echo "❌ Error: multiple actions specified." >&2
      exit 1
    }
    ACTION="unset"
    shift
    ;;
  --)
    shift
    break
    ;;
  -*)
    echo "❌ Unknown option: $1" >&2
    exit 1
    ;;
  *)
    [ -n "$ACTION" ] && {
      echo "❌ Error: cannot combine '$1' with another action." >&2
      exit 1
    }
    ACTION="set"
    TARGET_NAME="$1"
    shift
    ;;
  esac
done

# Anything after "--" is a positional name.
if [ $# -gt 0 ]; then
  if [ -n "$ACTION" ]; then
    echo "❌ Error: too many arguments: $*" >&2
    exit 1
  fi
  ACTION="set"
  TARGET_NAME="$1"
  shift
fi

[ $# -gt 0 ] && {
  echo "❌ Error: too many arguments: $*" >&2
  exit 1
}

[ -z "$ACTION" ] && ACTION="show"

# --- Dispatch -------------------------------------------

case "$ACTION" in
show)
  show_status
  ;;
set)
  set_toolchain "$TARGET_NAME" || exit 1
  ;;
unset)
  unset_toolchain
  ;;
menu)
  define_toolchain_menu
  menu_run toolchain_menu || exit 1
  ;;
esac