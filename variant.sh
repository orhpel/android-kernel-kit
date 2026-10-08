#!/usr/bin/env bash
# ========================================================
# Android Kernel Kit
#
# --- variant.sh ---
# Build-variant support: named patches that transform a kernel
# .config into a device-specific configuration. Sourced by
# variant-it.sh and build-it.sh. Never executed.
#
# A variant file lives at <PROJECT_ROOT>/.variants/<name>.cfg.
# Format: one directive per line.
#   + KEY           enable KEY (KEY=y)
#   + KEY=VALUE     set KEY to VALUE
#   - KEY           disable KEY (# KEY is not set)
#
# Missing keys and "# KEY is not set" lines are equivalent for the
# purpose of diffing — both mean "off".
# ========================================================

if [ "${_VARIANT_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
_VARIANT_SH_LOADED=1

# Dependencies: _cfg_project_root and warn from common.sh.
if ! declare -F _cfg_project_root >/dev/null 2>&1; then
  echo "❌ variant.sh: source common.sh before variant.sh." >&2
  return 1
fi

# --- Paths ----------------------------------------------

# variant_dir
#   Print the .variants directory of the current project.
#   Returns 1 if we are not inside a project.
variant_dir() {
  local root; root="$(_cfg_project_root)"
  [ -n "$root" ] || return 1
  printf '%s\n' "${root}/.variants"
}

# variant_path <name>
#   Print the full path to a variant file.
variant_path() {
  local name="${1:-}"
  [ -n "$name" ] || return 1
  local dir; dir="$(variant_dir)" || return 1
  printf '%s\n' "${dir}/${name}.cfg"
}

# variant_exists <name>
variant_exists() {
  local name="${1:-}"
  [ -n "$name" ] || return 1
  local p; p="$(variant_path "$name")" || return 1
  [ -f "$p" ]
}

# variant_list
#   Print all variant names, one per line. Sorted.
variant_list() {
  local dir; dir="$(variant_dir)" || return 1
  [ -d "$dir" ] || return 0
  local f
  for f in "$dir"/*.cfg; do
    [ -f "$f" ] || continue
    basename -- "$f" .cfg
  done | LC_ALL=C sort
}

# --- Parsing --------------------------------------------

# _variant_parse_config <file> <map_nameref>
#   Populate <map> with KEY=VALUE pairs from a .config file.
#   Lines starting with '#' are skipped; "# KEY is not set" and a
#   missing key are equivalent (both "off").
_variant_parse_config() {
  local file="$1"
  local -n _vpc_map="$2"
  _vpc_map=()

  [ -f "$file" ] || return 1

  local line trimmed key value
  while IFS= read -r line || [ -n "$line" ]; do
    # Trim leading and trailing whitespace.
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

    case "$trimmed" in
      ''|'#'*) continue ;;
    esac
    [[ "$trimmed" == *=* ]] || continue

    key="${trimmed%%=*}"
    value="${trimmed#*=}"
    _vpc_map["$key"]="$value"
  done < "$file"
}

# --- Diff -----------------------------------------------

# variant_diff <from_config> <to_config>
#   Emit variant directives that transform <from_config> into
#   <to_config> for every key whose value differs.
variant_diff() {
  local file_from="$1" file_to="$2"
  [ -f "$file_from" ] || { echo "❌ variant_diff: not a file: $file_from" >&2; return 1; }
  [ -f "$file_to" ]   || { echo "❌ variant_diff: not a file: $file_to" >&2; return 1; }

  local -A from_map=() to_map=()
  _variant_parse_config "$file_from" from_map
  _variant_parse_config "$file_to"   to_map

  local -A all_keys=()
  local k
  for k in "${!from_map[@]}"; do all_keys["$k"]=1; done
  for k in "${!to_map[@]}";   do all_keys["$k"]=1; done

  local -a sorted=()
  mapfile -t sorted < <(printf '%s\n' "${!all_keys[@]}" | LC_ALL=C sort)

  local from_v to_v
  for k in "${sorted[@]}"; do
    # \x01 is our "key absent" sentinel.
    from_v="${from_map[$k]-$'\x01'}"
    to_v="${to_map[$k]-$'\x01'}"
    [ "$from_v" = "$to_v" ] && continue

    if [ "$to_v" = $'\x01' ]; then
      printf -- '- %s\n' "$k"
    elif [ "$to_v" = "y" ]; then
      printf -- '+ %s\n' "$k"
    else
      printf -- '+ %s=%s\n' "$k" "$to_v"
    fi
  done
}

# --- Application ----------------------------------------

# _variant_directive_to_line <prefix> <key> <value>
#   Convert a directive to the .config line it represents.
_variant_directive_to_line() {
  local prefix="$1" key="$2" value="${3-}"
  case "$prefix" in
    '+')
      if [ -z "$value" ]; then
        printf '%s=y\n' "$key"
      else
        printf '%s=%s\n' "$key" "$value"
      fi
      ;;
    '-') printf '# %s is not set\n' "$key" ;;
  esac
}

# variant_apply <name> [<config>]
#   Apply a variant to <config> (default: ./.config).
#   Every directive key is stripped from the target first, then the
#   directive lines are appended. Idempotent.
variant_apply() {
  local name="${1:-}"
  local config="${2:-.config}"
  [ -n "$name" ] || { echo "❌ variant_apply: name required." >&2; return 1; }

  local vfile; vfile="$(variant_path "$name")" || return 1
  [ -f "$vfile" ] || { echo "❌ variant_apply: variant '$name' not found." >&2; return 1; }
  [ -f "$config" ] || { echo "❌ variant_apply: config '$config' not found." >&2; return 1; }

  # Parse directives into a removal set and a list of new lines.
  local -A remove=()
  local -a new_lines=()
  local line prefix rest key value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    prefix="${line:0:1}"
    case "$prefix" in
      '+'|'-') ;;
      *) warn "variant: ignoring malformed line: $line"; continue ;;
    esac
    rest="${line:2}"
    if [[ "$rest" == *=* ]]; then
      key="${rest%%=*}"
      value="${rest#*=}"
    else
      key="$rest"
      value=""
    fi
    [ -z "$key" ] && continue
    remove["$key"]=1
    new_lines+=("$(_variant_directive_to_line "$prefix" "$key" "$value")")
  done < "$vfile"

  if [ "${#new_lines[@]}" -eq 0 ]; then
    echo "ℹ️  Variant '$name' has no directives." >&2
    return 0
  fi

  # Single pass: filter out every line whose key is being replaced,
  # then append the new directive lines.
  local tmp; tmp="$(mktemp "${config}.XXXXXX")" || return 1
  local lk
  while IFS= read -r line || [ -n "$line" ]; do
    lk=""
    case "$line" in
      '# '*)
        lk="${line#\# }"
        lk="${lk%% *}"
        ;;
      *=*)
        lk="${line%%=*}"
        ;;
    esac
    if [ -n "$lk" ] && [ -n "${remove[$lk]+set}" ]; then
      continue
    fi
    printf '%s\n' "$line"
  done < "$config" > "$tmp"

  printf '%s\n' "${new_lines[@]}" >> "$tmp"

  chmod 0644 "$tmp"
  mv -- "$tmp" "$config"
  return 0
}

# --- Normalization --------------------------------------

# variant_normalize
#   Run the configured normalizer after a variant is applied.
#   Honors KIT_BUILD_CFG_VARIANT_NORMALIZE (off | olddefconfig | oldconfig).
variant_normalize() {
  local mode="${KIT_BUILD_CFG_VARIANT_NORMALIZE:-off}"
  case "$mode" in
    off|"") return 0 ;;
    olddefconfig|oldconfig) ;;
    *) warn "Unknown normalize mode '$mode'; skipping."; return 0 ;;
  esac

  command -v make >/dev/null 2>&1 || { warn "make not found; cannot run $mode."; return 1; }

  if [ "$mode" = "oldconfig" ] && ! [ -t 0 ]; then
    warn "oldconfig is interactive but stdin is not a TTY; skipping."
    return 1
  fi

  echo "🔧 Running 'make $mode' ..." >&2
  make "$mode" >&2
}

# --- Management -----------------------------------------

# variant_delete <name>
variant_delete() {
  local name="${1:-}"
  [ -n "$name" ] || return 1
  local p; p="$(variant_path "$name")" || return 1
  [ -f "$p" ] || return 1
  rm -f -- "$p"
}

# variant_read_directives <name>
#   Print the variant file content.
variant_read_directives() {
  local name="${1:-}"
  [ -n "$name" ] || return 1
  local p; p="$(variant_path "$name")" || return 1
  [ -f "$p" ] || return 1
  cat -- "$p"
}

# variant_save_directives <name> <file>
#   Copy <file> (which contains directives) to the variant <name>.
#   Prints the destination path on success.
variant_save_directives() {
  local name="${1:-}" src="${2:-}"
  [ -n "$name" ] || { echo "❌ variant_save_directives: name required." >&2; return 1; }
  [ -f "$src" ] || { echo "❌ variant_save_directives: source file not found: $src" >&2; return 1; }

  local dir; dir="$(variant_dir)" || return 1
  mkdir -p -- "$dir" || return 1

  local dst="${dir}/${name}.cfg"
  cp -- "$src" "$dst" || return 1
  chmod 0644 "$dst"
  printf '%s\n' "$dst"
}

# variant_matches <name> [<config>]
#   Return 0 if every directive in the variant is already satisfied
#   by <config> (default: ./.config).
#
#   A directive is satisfied when the current value in <config>
#   equals what the directive would set:
#     + KEY           → KEY is set to y
#     + KEY=VALUE     → KEY is set to VALUE
#     - KEY           → KEY is off (absent, or "is not set")
variant_matches() {
  local name="${1:-}" config="${2:-.config}"
  [ -n "$name" ] || return 1
  [ -f "$config" ] || return 1

  local vfile; vfile="$(variant_path "$name")" || return 1
  [ -f "$vfile" ] || return 1

  local -A config_map=()
  _variant_parse_config "$config" config_map

  local line prefix rest key want
  local seen=0

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    prefix="${line:0:1}"
    case "$prefix" in
      '+'|'-') ;;
      *) continue ;;
    esac
    rest="${line:2}"
    if [[ "$rest" == *=* ]]; then
      key="${rest%%=*}"
      want="${rest#*=}"
    else
      key="$rest"
      want=""
    fi
    [ -z "$key" ] && continue
    seen=$((seen + 1))

    local current="${config_map[$key]-}"
    case "$prefix" in
      '-')
        [ -z "$current" ] || return 1
        ;;
      '+')
        if [ -z "$want" ]; then
          [ "$current" = "y" ] || return 1
        else
          [ "$current" = "$want" ] || return 1
        fi
        ;;
    esac
  done < "$vfile"

  [ "$seen" -gt 0 ] || return 1
  return 0
}

# variant_detect [<config>]
#   Print the name of every variant whose directives are already
#   satisfied by <config>. One per line. Variants with no directives
#   are skipped — they'd match trivially.
variant_detect() {
  local config="${1:-.config}"
  [ -f "$config" ] || return 1

  local name
  while IFS= read -r name; do
    variant_matches "$name" "$config" && printf '%s\n' "$name"
  done < <(variant_list)
}