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
#: "${KIT_MENU_CFG_SYMBOL_ACTION:=$'\uf4b5'}" Nerdfont version
: "${KIT_MENU_CFG_SYMBOL_ACTION:=▶}"
: "${KIT_MENU_CFG_SYMBOL_BACK:=↩}"
: "${KIT_MENU_CFG_SYMBOL_CHECKED:=✅}"
: "${KIT_MENU_CFG_SYMBOL_UNCHECKED:=⬛}"
#: "${KIT_MENU_CFG_SYMBOL_SUBMENU:=$'\uf114'}" Nerdfont version
: "${KIT_MENU_CFG_SYMBOL_SUBMENU:=📁}"

# gum choose styling. These are passed to gum directly, so they use
# gum's own color handling and are independent of any label content.
: "${KIT_MENU_CFG_COLOR_CURSOR:=212}"
: "${KIT_MENU_CFG_COLOR_SELECTED:=}"
: "${KIT_MENU_CFG_COLOR_ITEM:=}"
: "${KIT_MENU_CFG_COLOR_HEADER:=}"

# _display_width <string>
#   Visual width of <string> in terminal cells. Delegates to the
#   system's wcwidth() via `wc -L`, so the result matches what the
#   terminal actually renders — including locale-specific rules
#   (e.g. 'ambiguous-width' symbols like ▶ are 1 cell in a Western
#   locale, 2 in a CJK locale) and emoji width (always 2 on modern
#   libc).
#
#   No hardcoded symbol list. Users can configure any glyph via
#   config-it and the alignment stays correct.
_display_width() {
  local s="$1"
  printf '%s' "$s" | wc -L
}

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
      --pattern)     key="pattern";     val="$2"; shift 2 ;;
      --hint)        key="hint";        val="$2"; shift 2 ;;
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

# _menu_status_string <key>
#   Return the rendered status string for an entry, or an empty
#   string for entry types that don't carry one (action, submenu).
#   Extracted from _menu_render_label so the runner can compute the
#   widest status across a menu and pad every entry to match.
_menu_status_string() {
  local key="$1"
  local type="${_MENU_TYPE[$key]}"
  local var="${_MENU_VAR[$key]:-}"
  case "$type" in
    bool)
      if [ "$(_menu_get_var "$var")" = "1" ]; then
        printf '%s' "$KIT_MENU_CFG_SYMBOL_CHECKED"
      else
        printf '%s' "$KIT_MENU_CFG_SYMBOL_UNCHECKED"
      fi
      ;;
    enum|int|string|file|dir)
      printf '[%s]' "$(_menu_get_var "$var")"
      ;;
    *)
      printf ''
      ;;
  esac
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
  local status_pad="${3:-0}"
  local type="${_MENU_TYPE[$key]}"
  local label="${_MENU_LABEL[$key]}"
  local desc="${_MENU_DESC[$key]:-}"
  local out

  if [ "$type" = "action" ]; then
    out="${KIT_MENU_CFG_SYMBOL_ACTION} ${label}"
  else
    local label_w
    label_w="$(_display_width "$label")"
    if [ "$label_w" -lt "$pad_width" ]; then
      printf -v label '%s%*s' "$label" "$((pad_width - label_w))" ""
    fi

    case "$type" in
      submenu)
        out="${KIT_MENU_CFG_SYMBOL_SUBMENU} ${label} >"
        ;;
      bool|enum|int|string|file|dir)
        local st st_padded st_w
        st="$(_menu_status_string "$key")"
        st_w="$(_display_width "$st")"
        st_padded="$st"
        if [ "$st_w" -lt "$status_pad" ]; then
          printf -v st_padded '%s%*s' "$st" "$((status_pad - st_w))" ""
        fi
        out="${label}  ${st_padded}"
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

# _menu_editor_header <label> [<hint>]
#   Compose the header string for gum input editors. When the box
#   style is enabled, wraps the label and hint in box-drawing chars
#   and — if a NerdFont-capable terminal is configured — prepends a
#   pencil icon to the label.
_menu_editor_header() {
  local label="$1" hint="${2:-}"
  local style="${KIT_MENU_CFG_EDITOR_BOX:-unicode}"
  local icon=""

  if [ "$style" != "off" ] && [ -n "$style" ] \
     && [ "${KIT_COMMON_CFG_NERDFONT:-0}" = "1" ]; then
    icon=$'\uf040 '
  fi

  if [ "$style" = "off" ] || [ -z "$style" ]; then
    if [ -n "$hint" ]; then
      printf '%s\n%s' "$label" "$hint"
    else
      printf '%s' "$label"
    fi
    return 0
  fi

  case "$style" in
    rounded) printf '╭─%s%s\n' "$icon" "$label" ;;
    *)       printf '┌─%s%s\n' "$icon" "$label" ;;
  esac

  if [ -n "$hint" ]; then
    local line
    while IFS= read -r line; do
      printf '│  %s\n' "$line"
    done <<<"$hint"
  fi

  printf '│'
}

_menu_edit_enum() {
  local key="$1" var="$2" label="$3" payload="$4" flags="${5:-}"
  local -a opts=()
  mapfile -t opts <<<"$payload"

  local hint=""
  hint=$(_menu_flag_val "$flags" hint || true)

  local header
  header="$(_menu_editor_header "$label" "$hint")"

  local cur; cur="$(_menu_get_var "$var")"
  local -a args=(--header "$header")
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
  local min max hint
  min=$(_menu_flag_val "$flags" min || true)
  max=$(_menu_flag_val "$flags" max || true)
  hint=$(_menu_flag_val "$flags" hint || true)

  local header; header="$(_menu_editor_header "$label" "$hint")"
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
  if new=$(gum input --header "$header" --value "$cur" --placeholder "$placeholder"); then
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
  local placeholder="" hint="" pattern=""
  placeholder=$(_menu_flag_val "$flags" placeholder || true)
  hint=$(_menu_flag_val "$flags" hint || true)
  pattern=$(_menu_flag_val "$flags" pattern || true)

	local header; header="$(_menu_editor_header "$label" "$hint")"
  local cur; cur="$(_menu_get_var "$var")"
  local new
  while true; do
    if ! new=$(gum input --header "$header" --value "$cur" --placeholder "$placeholder"); then
      return 0
    fi
    if [ -n "$pattern" ] && ! [[ "$new" =~ $pattern ]]; then
      echo "❌ Input does not match pattern: $pattern" >&2
      # Keep the bad input so the user can fix it in place.
      cur="$new"
      continue
    fi
    _menu_set_var "$var" "$new"
    return 0
  done
}

_menu_edit_path() {
  local key="$1" var="$2" label="$3" flags="$4" kind="$5"

  local hint
  hint=$(_menu_flag_val "$flags" hint || true)
  local header; header="$(_menu_editor_header "$label" "$hint")"
  local placeholder="/path/to/..."
  [ "$kind" = "dir" ] && placeholder="/path/to/directory"

  local new
  if ! new=$(gum input --header "$header" --value "$cur" --placeholder "$placeholder"); then
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
    enum)   _menu_edit_enum   "$key" "$var" "$label" "$payload" "$flags" ;;
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
  # Recursion depth, passed by the parent menu's submenu dispatcher.
  # Depth 0 = top-level menu (no Back button). Depth ≥1 = opened from
  # a parent menu (Back button appended).
  local depth="${2:-0}"
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

  local back_label=""
  [ "$depth" -gt 0 ] && back_label="${KIT_MENU_CFG_SYMBOL_BACK} Back"

	local -a labels=()
  local i choice idx key type prev_idx=0
	local -a choose_args
  local max_w max_status_w
  local _st _sw _lw

  while true; do
    # Compute the label padding width and the status padding width
    # separately, so value entries line up on both columns regardless
    # of their type.
    max_w=0
    max_status_w=0
    for ((i = 0; i < count; i++)); do
      key="${name}:${i}"
      [ "${_MENU_TYPE[$key]}" = "action" ] && continue
      [ "${_MENU_TYPE[$key]}" = "submenu" ] && continue
      _lw="$(_display_width "${_MENU_LABEL[$key]}")"
      [ "$_lw" -gt "$max_w" ] && max_w="$_lw"
      _st="$(_menu_status_string "$key")"
      _sw="$(_display_width "$_st")"
      [ "$_sw" -gt "$max_status_w" ] && max_status_w="$_sw"
    done

    labels=()
    for ((i = 0; i < count; i++)); do
      labels+=("$(_menu_render_label "${name}:${i}" "$max_w" "$max_status_w")")
    done

    # Append the Back entry when we were opened from a parent menu.
    # It is a pseudo-entry: no registry slot, index == count.
    [ -n "$back_label" ] && labels+=("$back_label")

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

    # Back pseudo-entry: same exit path as Esc — return 1, let the
    # parent menu (which called us via submenu dispatch with || true)
    # continue its loop.
    if [ -z "$idx" ] && [ -n "$back_label" ] && [ "$choice" = "$back_label" ]; then
      return 1
    fi

    if [ -z "$idx" ]; then
      echo "❌ menu_run: could not resolve selection." >&2
      return 1
    fi

    key="${name}:${idx}"
    type="${_MENU_TYPE[$key]}"

    case "$type" in
      submenu)
        menu_run "${_MENU_PAYLOAD[$key]}" "$((depth + 1))" || true
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
