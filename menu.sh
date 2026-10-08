#!/usr/bin/env bash
# ========================================================
# Android Kernel Kit
#
# --- menu.sh ---
## menu.sh (lib)
#
# Declarative menu DSL on top of `gum`. Sourced, never executed.
# Entry points defined under a name; runner dispatches by type.
# Value entries bind to a shell variable via indirect expansion;
# writes happen immediately (no deferred commit). Cancel leaves
# the variable untouched.
#
# ### Builder API
# - `menu_begin <title>`               → start a new menu definition
# - `menu_end <name>`                  → register under <name>
# - `menu_bool    <label> <var> [--desc] [--default 0|1]`
# - `menu_enum    <label> <var> <opt>... [--desc]`
# - `menu_int     <label> <var> [--min N] [--max N] [--desc]`
# - `menu_string  <label> <var> [--placeholder STR] [--desc]`
# - `menu_file    <label> <var> [--check] [--desc]`
# - `menu_dir     <label> <var> [--check] [--desc]`
# - `menu_action  <label> <cmd> [--close] [--confirm STR] [--desc]`
# - `menu_submenu <label> <target-menu> [--desc]`
#
# ### Runner
# - `menu_run <name>`  → render loop; returns 1 on cancel
#                         value changes commit immediately
#                         submenu cancels return to parent, not outer
#                         non-zero gum exit == cancel (state preserved)
# ========================================================

# --- Guard ----------------------------------------------

if [ "${_MENU_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
_MENU_SH_LOADED=1

# --- Dependencies ---------------------------------------

# Prefer being sourced after common.sh; fall back to sourcing it
# ourselves so menu.sh is usable standalone within the kit.
if ! declare -F require_gum >/dev/null 2>&1; then
  _menu_self_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  if [ -f "${_menu_self_dir}/common.sh" ]; then
    # shellcheck source=/dev/null
    source "${_menu_self_dir}/common.sh"
  fi
  unset _menu_self_dir
fi

if ! declare -F require_gum >/dev/null 2>&1; then
  echo "❌ menu.sh: 'require_gum' not defined. Source common.sh before menu.sh." >&2
  return 1
fi

# --- Separator ------------------------------------------

# Field separator for the per-entry flags string and for the
# invisible index suffix on rendered labels. 0x1F = ASCII US,
# which is not expected to appear in user-provided text.
readonly _MENU_SEP=$'\x1f'

# --- State ----------------------------------------------

# Persistent menu registry, filled by menu_end.
declare -gA _MENU_TITLE
declare -gA _MENU_COUNT
declare -gA _MENU_LABEL
declare -gA _MENU_TYPE
declare -gA _MENU_VAR
declare -gA _MENU_DESC
declare -gA _MENU_PAYLOAD
declare -gA _MENU_FLAGS

# Builder state (only valid between menu_begin and menu_end).
declare -g _MENU_BUILD_ACTIVE=0
declare -g _MENU_BUILD_NAME=""
declare -g _MENU_BUILD_COUNT=0

# Parser output from _menu_parse_flags.
declare -g _MENU_ARG_DESC=""
declare -g _MENU_ARG_FLAGS=""

# --- Appearance ----------------------------------------

# Symbols used in rendered labels. Override before sourcing if needed.
: "${KIT_MENU_CFG_SYMBOL_CHECKED:=✅}"
: "${KIT_MENU_CFG_SYMBOL_UNCHECKED:=⬛}"
: "${KIT_MENU_CFG_SYMBOL_SUBMENU:=→}"

# gum choose styling. These are passed to gum directly, so they use
# gum's own color handling and are independent of any label content.
: "${KIT_MENU_CFG_COLOR_CURSOR:=212}"
: "${KIT_MENU_CFG_COLOR_SELECTED:=}"
: "${KIT_MENU_CFG_COLOR_ITEM:=}"
: "${KIT_MENU_CFG_COLOR_HEADER:=}"

# --- Value access ---------------------------------------

# Read a variable by name; empty string if unset.
_menu_get_var() {
  local name="${1:?}"
  printf '%s' "${!name-}"
}

# Write a variable by name.
_menu_set_var() {
  local name="${1:?}" value="${2-}"
  printf -v "$name" '%s' "$value"
}

# --- Flag handling --------------------------------------

# _menu_parse_flags [flags...]
#   Sets _MENU_ARG_DESC and _MENU_ARG_FLAGS from the trailing
#   long options of a menu_* entry. Recognised flags:
#     --desc <text>
#     --close
#     --check
#     --confirm <text>
#     --min <n>
#     --max <n>
#     --placeholder <text>
_menu_parse_flags() {
  _MENU_ARG_DESC=""
  _MENU_ARG_FLAGS=""

  while [ $# -gt 0 ]; do
    local key="" val=""
    case "$1" in
      --desc)        key="desc";        val="$2"; shift 2 ;;
      --confirm)     key="confirm";     val="$2"; shift 2 ;;
      --min)         key="min";         val="$2"; shift 2 ;;
      --max)         key="max";         val="$2"; shift 2 ;;
      --placeholder) key="placeholder"; val="$2"; shift 2 ;;
      --close)       key="close";       shift ;;
      --check)       key="check";       shift ;;
      *)
        echo "❌ menu: unknown flag '$1'." >&2
        return 1
        ;;
    esac

    if [ "$key" = "desc" ]; then
      _MENU_ARG_DESC="$val"
    elif [ -n "$val" ]; then
      _MENU_ARG_FLAGS+="${_MENU_SEP}${key}=${val}"
    else
      _MENU_ARG_FLAGS+="${_MENU_SEP}${key}"
    fi
  done
  return 0
}

# _menu_has_flag <flags> <name>   -> 0 if present
_menu_has_flag() {
  local flags="$1" name="$2" f
  local IFS="$_MENU_SEP"
  for f in $flags; do
    [ "$f" = "$name" ] && return 0
  done
  return 1
}

# _menu_flag_val <flags> <name>   -> prints value, 1 if absent
_menu_flag_val() {
  local flags="$1" name="$2" f
  local IFS="$_MENU_SEP"
  for f in $flags; do
    case "$f" in
      "${name}="*) printf '%s' "${f#"${name}="}"; return 0 ;;
    esac
  done
  return 1
}

# --- Builder internals ----------------------------------

# _menu_push <type> <label> <var> <payload> <desc> <flags>
_menu_push() {
  if [ "$_MENU_BUILD_ACTIVE" -ne 1 ]; then
    echo "❌ menu: entry '$2' declared outside of menu_begin / menu_end." >&2
    return 1
  fi

  local type="$1" label="$2" var="$3" payload="$4" desc="$5" flags="$6"
  local name="$_MENU_BUILD_NAME"
  local idx="$_MENU_BUILD_COUNT"
  local key="${name}:${idx}"

  _MENU_LABEL["$key"]="$label"
  _MENU_TYPE["$key"]="$type"
  _MENU_VAR["$key"]="$var"
  _MENU_DESC["$key"]="$desc"
  _MENU_PAYLOAD["$key"]="$payload"
  _MENU_FLAGS["$key"]="$flags"

  _MENU_BUILD_COUNT=$((idx + 1))
  _MENU_COUNT["$name"]="$_MENU_BUILD_COUNT"
  return 0
}

# _menu_rename_key <array> <old> <new>
_menu_rename_key() {
  local -n _mrk_arr="$1"
  local old="$2" new="$3"
  if [ "${_mrk_arr[$old]+set}" = "set" ]; then
    _mrk_arr["$new"]="${_mrk_arr[$old]}"
    unset "_mrk_arr[$old]"
  fi
}

# --- Builder API ----------------------------------------

menu_begin() {
  local title="${1:-}"
  if [ -z "$title" ]; then
    echo "❌ menu_begin: title required." >&2
    return 1
  fi
  if [ "$_MENU_BUILD_ACTIVE" -eq 1 ]; then
    echo "❌ menu_begin: a menu is already being built." >&2
    return 1
  fi

  _MENU_BUILD_ACTIVE=1
  _MENU_BUILD_NAME="__menu_build__"
  _MENU_BUILD_COUNT=0
  _MENU_TITLE["$_MENU_BUILD_NAME"]="$title"
  _MENU_COUNT["$_MENU_BUILD_NAME"]=0
  return 0
}

menu_end() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    echo "❌ menu_end: menu name required." >&2
    return 1
  fi
  if [ "$_MENU_BUILD_ACTIVE" -ne 1 ]; then
    echo "❌ menu_end: no menu is currently being built." >&2
    return 1
  fi
  if [ -n "${_MENU_TITLE[$name]+set}" ]; then
    echo "❌ menu_end: menu '$name' already exists." >&2
    return 1
  fi

  local src="$_MENU_BUILD_NAME"
  local count="$_MENU_BUILD_COUNT"
  local i arr

  _MENU_TITLE["$name"]="${_MENU_TITLE[$src]}"
  _MENU_COUNT["$name"]="$count"

  for ((i = 0; i < count; i++)); do
    for arr in _MENU_LABEL _MENU_TYPE _MENU_VAR _MENU_DESC _MENU_PAYLOAD _MENU_FLAGS; do
      _menu_rename_key "$arr" "${src}:${i}" "${name}:${i}"
    done
  done

  unset "_MENU_TITLE[$src]" "_MENU_COUNT[$src]"
  _MENU_BUILD_ACTIVE=0
  _MENU_BUILD_NAME=""
  _MENU_BUILD_COUNT=0
  return 0
}

# --- Entry API ------------------------------------------

menu_submenu() {
  local label="${1:-}" target="${2:-}"; shift 2 || true
  if [ -z "$label" ] || [ -z "$target" ]; then
    echo "❌ menu_submenu: <label> <menu_name> required." >&2
    return 1
  fi
  _menu_parse_flags "$@" || return 1
  _menu_push submenu "$label" "" "$target" "$_MENU_ARG_DESC" "$_MENU_ARG_FLAGS"
}

menu_action() {
  local label="${1:-}" command="${2:-}"; shift 2 || true
  if [ -z "$label" ] || [ -z "$command" ]; then
    echo "❌ menu_action: <label> <command> required." >&2
    return 1
  fi
  _menu_parse_flags "$@" || return 1
  _menu_push action "$label" "" "$command" "$_MENU_ARG_DESC" "$_MENU_ARG_FLAGS"
}

menu_bool() {
  local label="${1:-}" var="${2:-}"; shift 2 || true
  if [ -z "$label" ] || [ -z "$var" ]; then
    echo "❌ menu_bool: <label> <var> required." >&2
    return 1
  fi
  _menu_parse_flags "$@" || return 1
  _menu_push bool "$label" "$var" "" "$_MENU_ARG_DESC" "$_MENU_ARG_FLAGS"
}

menu_enum() {
  local label="${1:-}" var="${2:-}"; shift 2 || true
  if [ -z "$label" ] || [ -z "$var" ]; then
    echo "❌ menu_enum: <label> <var> <option>... required." >&2
    return 1
  fi

  local -a options=()
  while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
    options+=("$1"); shift
  done
  if [ "${#options[@]}" -eq 0 ]; then
    echo "❌ menu_enum '$label': at least one option required." >&2
    return 1
  fi

  _menu_parse_flags "$@" || return 1
  local payload
  payload=$(printf '%s\n' "${options[@]}")
  _menu_push enum "$label" "$var" "$payload" "$_MENU_ARG_DESC" "$_MENU_ARG_FLAGS"
}

menu_int() {
  local label="${1:-}" var="${2:-}"; shift 2 || true
  if [ -z "$label" ] || [ -z "$var" ]; then
    echo "❌ menu_int: <label> <var> required." >&2
    return 1
  fi
  _menu_parse_flags "$@" || return 1
  _menu_push int "$label" "$var" "" "$_MENU_ARG_DESC" "$_MENU_ARG_FLAGS"
}

menu_string() {
  local label="${1:-}" var="${2:-}"; shift 2 || true
  if [ -z "$label" ] || [ -z "$var" ]; then
    echo "❌ menu_string: <label> <var> required." >&2
    return 1
  fi
  _menu_parse_flags "$@" || return 1
  _menu_push string "$label" "$var" "" "$_MENU_ARG_DESC" "$_MENU_ARG_FLAGS"
}

menu_file() {
  local label="${1:-}" var="${2:-}"; shift 2 || true
  if [ -z "$label" ] || [ -z "$var" ]; then
    echo "❌ menu_file: <label> <var> required." >&2
    return 1
  fi
  _menu_parse_flags "$@" || return 1
  _menu_push file "$label" "$var" "" "$_MENU_ARG_DESC" "$_MENU_ARG_FLAGS"
}

menu_dir() {
  local label="${1:-}" var="${2:-}"; shift 2 || true
  if [ -z "$label" ] || [ -z "$var" ]; then
    echo "❌ menu_dir: <label> <var> required." >&2
    return 1
  fi
  _menu_parse_flags "$@" || return 1
  _menu_push dir "$label" "$var" "" "$_MENU_ARG_DESC" "$_MENU_ARG_FLAGS"
}

# --- Rendering ------------------------------------------

_menu_render_label() {
  local key="$1"
  local pad_width="${2:-0}"
  local type="${_MENU_TYPE[$key]}"
  local label="${_MENU_LABEL[$key]}"
  local var="${_MENU_VAR[$key]:-}"
  local desc="${_MENU_DESC[$key]:-}"
  local out

  if [ "$type" = "action" ]; then
    out="[${label}]"
  else
    if [ "${#label}" -lt "$pad_width" ]; then
      printf -v label '%s%*s' "$label" "$((pad_width - ${#label}))" ""
    fi

    case "$type" in
      submenu)
        out="${KIT_MENU_CFG_SYMBOL_SUBMENU} ${label}"
        ;;
      bool)
        local v; v="$(_menu_get_var "$var")"
        if [ "$v" = "1" ]; then
          out="${label}  ${KIT_MENU_CFG_SYMBOL_CHECKED}"
        else
          out="${label}  ${KIT_MENU_CFG_SYMBOL_UNCHECKED}"
        fi
        ;;
      enum|int|string|file|dir)
        out="${label}  [$(_menu_get_var "$var")]"
        ;;
      *)
        out="$label"
        ;;
    esac
  fi

  [ -n "$desc" ] && out+="  —  ${desc}"
  printf '%s' "$out"
}

# --- Value editors --------------------------------------

_menu_edit_enum() {
  local key="$1" var="$2" label="$3" payload="$4"
  local -a opts=()
  mapfile -t opts <<<"$payload"

  local cur; cur="$(_menu_get_var "$var")"
  local -a args=(--header "$label")
  local o
  for o in "${opts[@]}"; do
    if [ "$o" = "$cur" ]; then
      args+=(--selected "$cur")
      break
    fi
  done

  local picked
  if picked=$(gum choose "${args[@]}" "${opts[@]}"); then
    _menu_set_var "$var" "$picked"
  fi
  return 0
}

_menu_edit_int() {
  local key="$1" var="$2" label="$3" flags="$4"
  local min max
  min=$(_menu_flag_val "$flags" min || true)
  max=$(_menu_flag_val "$flags" max || true)

  local cur; cur="$(_menu_get_var "$var")"
  local placeholder="integer"
  if [ -n "$min" ] && [ -n "$max" ]; then
    placeholder="between ${min} and ${max}"
  elif [ -n "$min" ]; then
    placeholder=">= ${min}"
  elif [ -n "$max" ]; then
    placeholder="<= ${max}"
  fi

  local new
  if new=$(gum input --header "$label" --value "$cur" --placeholder "$placeholder"); then
    if ! [[ "$new" =~ ^-?[0-9]+$ ]]; then
      echo "❌ '$new' is not an integer." >&2
      return 0
    fi
    if [ -n "$min" ] && [ "$new" -lt "$min" ]; then
      echo "❌ Value must be >= $min." >&2
      return 0
    fi
    if [ -n "$max" ] && [ "$new" -gt "$max" ]; then
      echo "❌ Value must be <= $max." >&2
      return 0
    fi
    _menu_set_var "$var" "$new"
  fi
  return 0
}

_menu_edit_string() {
  local key="$1" var="$2" label="$3" flags="$4"
  local placeholder=""
  placeholder=$(_menu_flag_val "$flags" placeholder || true)

  local cur; cur="$(_menu_get_var "$var")"
  local new
  if new=$(gum input --header "$label" --value "$cur" --placeholder "$placeholder"); then
    _menu_set_var "$var" "$new"
  fi
  return 0
}

_menu_edit_path() {
  local key="$1" var="$2" label="$3" flags="$4" kind="$5"

  local cur; cur="$(_menu_get_var "$var")"
  local placeholder="/path/to/..."
  [ "$kind" = "dir" ] && placeholder="/path/to/directory"

  local new
  if ! new=$(gum input --header "$label" --value "$cur" --placeholder "$placeholder"); then
    return 0
  fi

  if _menu_has_flag "$flags" check; then
    if [ "$kind" = "file" ] && [ ! -f "$new" ]; then
      echo "❌ Not a file: $new" >&2
      return 0
    fi
    if [ "$kind" = "dir" ] && [ ! -d "$new" ]; then
      echo "❌ Not a directory: $new" >&2
      return 0
    fi
  fi

  _menu_set_var "$var" "$new"
  return 0
}

_menu_edit_value() {
  local key="$1"
  local type="${_MENU_TYPE[$key]}"
  local var="${_MENU_VAR[$key]}"
  local label="${_MENU_LABEL[$key]}"
  local payload="${_MENU_PAYLOAD[$key]:-}"
  local flags="${_MENU_FLAGS[$key]:-}"

  case "$type" in
    enum)   _menu_edit_enum   "$key" "$var" "$label" "$payload" ;;
    int)    _menu_edit_int    "$key" "$var" "$label" "$flags" ;;
    string) _menu_edit_string "$key" "$var" "$label" "$flags" ;;
    file)   _menu_edit_path   "$key" "$var" "$label" "$flags" "file" ;;
    dir)    _menu_edit_path   "$key" "$var" "$label" "$flags" "dir" ;;
  esac
  return 0
}

# --- Action runner --------------------------------------

# Returns:
#   0 -> continue the loop
#   1 -> close the current menu (success)
_menu_run_action() {
  local key="$1"
  local label="${_MENU_LABEL[$key]}"
  local cmd="${_MENU_PAYLOAD[$key]}"
  local flags="${_MENU_FLAGS[$key]:-}"

  local confirm_prompt
  if confirm_prompt=$(_menu_flag_val "$flags" confirm); then
    gum confirm --prompt.foreground 4 "$confirm_prompt" || return 0
  fi

  # shellcheck disable=SC2086 # cmd is intentionally evaluated as a string
  eval "$cmd"

  if _menu_has_flag "$flags" close; then
    return 1
  fi
  return 0
}

# --- Runner ---------------------------------------------

menu_run() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    echo "❌ menu_run: menu name required." >&2
    return 1
  fi
  if [ -z "${_MENU_TITLE[$name]+set}" ]; then
    echo "❌ menu_run: unknown menu '$name'." >&2
    return 1
  fi

  require_gum || return 1

  local title="${_MENU_TITLE[$name]}"
  local count="${_MENU_COUNT[$name]}"
  if [ "$count" -eq 0 ]; then
    echo "❌ menu_run: menu '$name' has no entries." >&2
    return 1
  fi

    local -a labels=()
  local i choice idx key type prev_idx=0
  local -a choose_args
  local max_w lw

  while true; do
    # Compute the padding width from non-action entries, since only
    # those have a state column that needs alignment.
    max_w=0
    for ((i = 0; i < count; i++)); do
      key="${name}:${i}"
      [ "${_MENU_TYPE[$key]}" = "action" ] && continue
      lw="${#_MENU_LABEL[$key]}"
      [ "$lw" -gt "$max_w" ] && max_w="$lw"
    done

    labels=()
    for ((i = 0; i < count; i++)); do
      labels+=("$(_menu_render_label "${name}:${i}" "$max_w")")
    done

		choose_args=(--header "$title")
    [ -n "$KIT_MENU_CFG_COLOR_HEADER" ] && choose_args+=(--header.foreground "$KIT_MENU_CFG_COLOR_HEADER")
    [ -n "$KIT_MENU_CFG_COLOR_CURSOR" ] && choose_args+=(--cursor.foreground "$KIT_MENU_CFG_COLOR_CURSOR")
    [ -n "$KIT_MENU_CFG_COLOR_SELECTED" ] && choose_args+=(--selected.foreground "$KIT_MENU_CFG_COLOR_SELECTED")
    [ -n "$KIT_MENU_CFG_COLOR_ITEM" ] && choose_args+=(--item.foreground "$KIT_MENU_CFG_COLOR_ITEM")

    if [ -n "${labels[$prev_idx]:-}" ]; then
      choose_args+=(--selected "${labels[$prev_idx]}")
    fi

    if ! choice=$(gum choose "${choose_args[@]}" "${labels[@]}"); then
      return 1  # Esc / Ctrl-C
    fi

    idx=""
    for ((i = 0; i < count; i++)); do
      if [ "$choice" = "${labels[$i]}" ]; then
        idx="$i"; break
      fi
    done
    if [ -z "$idx" ]; then
      echo "❌ menu_run: could not resolve selection." >&2
      return 1
    fi

    key="${name}:${idx}"
    type="${_MENU_TYPE[$key]}"

    case "$type" in
      submenu)
        menu_run "${_MENU_PAYLOAD[$key]}" || true
        prev_idx=0
        ;;
      action)
        _menu_run_action "$key"
        [ $? -eq 1 ] && return 0
        prev_idx="$idx"
        ;;
      bool)
        local _bv; _bv="$(_menu_get_var "${_MENU_VAR[$key]}")"
        if [ "$_bv" = "1" ]; then
          _menu_set_var "${_MENU_VAR[$key]}" "0"
        else
          _menu_set_var "${_MENU_VAR[$key]}" "1"
        fi
        prev_idx="$idx"
        ;;
      enum|int|string|file|dir)
        _menu_edit_value "$key"
        prev_idx="$idx"
        ;;
      *)
        echo "❌ menu_run: unknown entry type '$type'." >&2
        return 1
        ;;
    esac
  done
}