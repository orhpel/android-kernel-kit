#!/usr/bin/env bash
# ========================================================
# Android Kernel Kit
#
# --- variant-it.sh ---
# Manage build variants for the current project.
#
# A variant is a named set of .config directives (+/- lines) that
# can be applied to the kernel's .config in one step. Variants live
# under <PROJECT_ROOT>/.variants/.
# ========================================================

# --- Help -----------------------------------------------

usage() {
  cat <<'EOF'
variant-it.sh - manage build variants for the current project

USAGE
    variant-it.sh [COMMAND] [ARGS...]

DESCRIPTION
    A build variant is a named patch that transforms the kernel's
    .config into a device-specific configuration. Variants are
    stored as plain text files under <PROJECT_ROOT>/.variants/,
    one directive per line:

        + CONFIG_FOO           enable CONFIG_FOO (y)
        + CONFIG_FOO=123       set CONFIG_FOO to 123
        - CONFIG_FOO           disable CONFIG_FOO

    Applying a variant removes every directive key from .config
    first, then appends the directive lines. The operation is
    idempotent — applying the same variant twice is safe.

    Without arguments, an interactive menu is shown.

COMMANDS
    (none)              Interactive menu
    list                Print all variant names
    show NAME           Print the contents of a variant
    detect              Test the current .config against every
                        defined variant and report matches		
    apply NAME          Apply a variant to .config, update the
                        active variant in .kit, run the configured
                        normalizer (see KIT_BUILD_CFG_VARIANT_NORMALIZE)
    create              Interactive workflow: pick two .config
                        files, preview both diffs, save two
                        variants (one per direction)
    delete NAME         Remove a variant
    -h, --help          Show this help and exit

EXIT STATUS
    0   success
    1   error (invalid arguments, missing variant, apply failure)
EOF
}

# --- Bootstrap ------------------------------------------

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/common.sh"
source "${KIT_DIR}/menu.sh"
source "${KIT_DIR}/variant.sh"

# --help must work outside a project too.
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

cd_project_root || exit 1
config_load

# --- Simple actions -------------------------------------

variant_it_list() {
	local active="${KIT_BUILD_CFG_VARIANT:-}"
  menu_action "Active: ${active:-(none)}" "variant_it_pick_apply" --close
}

variant_it_show() {
  local name="${1:-}"
  [ -n "$name" ] || { echo "❌ Error: variant name required." >&2; return 1; }
  variant_read_directives "$name" || {
    echo "❌ Error: variant '$name' not found." >&2
    return 1
  }
}

variant_it_apply() {
  local name="${1:-}"
  [ -n "$name" ] || { echo "❌ Error: variant name required." >&2; return 1; }

  if ! variant_exists "$name"; then
    echo "❌ Error: variant '$name' not found." >&2
    return 1
  fi

  variant_apply "$name" .config || {
    echo "❌ Error: failed to apply variant '$name'." >&2
    return 1
  }
  config_write KIT_BUILD_CFG_VARIANT "$name" >/dev/null
  echo "✅ Applied variant: $name"

  variant_normalize || warn "Config normalization failed; .config is patched but may need manual review."
  return 0
}

variant_it_delete() {
  local name="${1:-}"
  [ -n "$name" ] || { echo "❌ Error: variant name required." >&2; return 1; }
  variant_delete "$name" || {
    echo "❌ Error: variant '$name' not found." >&2
    return 1
  }
  echo "🗑  Deleted variant: $name"

  # If the deleted variant was active, clear the active setting.
  if [ "${KIT_BUILD_CFG_VARIANT:-}" = "$name" ]; then
    config_write KIT_BUILD_CFG_VARIANT "" >/dev/null
    echo "ℹ️  Cleared active variant (was '$name')."
  fi
}

variant_it_detect() {
  local -a matches=()
  mapfile -t matches < <(variant_detect .config)

  if [ "${#matches[@]}" -eq 0 ]; then
    echo "ℹ️  No variant matches the current .config."
    return 0
  fi

  local active="${KIT_BUILD_CFG_VARIANT:-}"
  local pick

  if [ "${#matches[@]}" -eq 1 ]; then
    pick="${matches[0]}"
    echo "✅ Current .config matches variant: $pick"
  else
    echo "Multiple variants match the current .config:"
    printf '  - %s\n' "${matches[@]}"
    if [ "${INTERACTIVE:-0}" -ne 1 ]; then
      return 0
    fi
    require_gum || return 1
    pick="$(printf '%s\n' "${matches[@]}" | gum choose --header 'Set which one as active?')" || return 0
    [ -z "$pick" ] && return 0
  fi

  # From here on we need a TTY to ask the user.
  if [ "${INTERACTIVE:-0}" -ne 1 ]; then
    if [ "$pick" != "$active" ]; then
      echo "ℹ️  Active variant is '${active:-none}'. Switch with 'variant-it.sh apply $pick'."
    fi
    return 0
  fi

  if [ "$pick" = "$active" ]; then
    echo "ℹ️  Active variant is already '$pick'."
    return 0
  fi

  require_gum || return 1
  if [ -z "$active" ]; then
    gum confirm "Set '$pick' as the active variant for this project?" || return 0
  else
    gum confirm "Active variant is '$active'. Switch to '$pick'?" || return 0
  fi

  config_write KIT_BUILD_CFG_VARIANT "$pick" >/dev/null
  echo "✅ Active variant set to: $pick"
}

# --- Interactive: create ---------------------------------

variant_it_create() {
  require_gum || return 1

  echo "🔀 Create variants from two .config files"
  echo

  local file_a file_b
  file_a="$(gum file --file . --header 'Select the FIRST .config file (baseline)')" || return 0
  [ -z "$file_a" ] && return 0
  [ -f "$file_a" ] || { warn "Not a file: $file_a"; return 0; }

  file_b="$(gum file --file . --header 'Select the SECOND .config file')" || return 0
  [ -z "$file_b" ] && return 0
  [ -f "$file_b" ] || { warn "Not a file: $file_b"; return 0; }

  local fwd bwd
  fwd="$(mktemp)"
  bwd="$(mktemp)"

  variant_diff "$file_a" "$file_b" > "$fwd"
  variant_diff "$file_b" "$file_a" > "$bwd"

  if [ ! -s "$fwd" ] && [ ! -s "$bwd" ]; then
    echo "ℹ️  The two .config files are identical — nothing to save."
    rm -f "$fwd" "$bwd"
    return 0
  fi

  # Build a preview that names each direction by its SOURCE file.
  local preview; preview="$(mktemp)"
  {
    printf '=== Variant for "%s" (starting from %s) ===\n\n' \
      "$(basename -- "$file_a")" "$(basename -- "$file_b")"
    cat "$bwd"
    printf '\n\n=== Variant for "%s" (starting from %s) ===\n\n' \
      "$(basename -- "$file_b")" "$(basename -- "$file_a")"
    cat "$fwd"
  } > "$preview"

  gum pager < "$preview"
  rm -f "$preview"

  local name_a name_b
  name_a="$(gum input \
    --header "Name for variant matching $(basename -- "$file_a"):" \
    --placeholder 'e.g. gtel3g')" || { rm -f "$fwd" "$bwd"; return 0; }
  [ -z "$name_a" ] && { rm -f "$fwd" "$bwd"; return 0; }

  name_b="$(gum input \
    --header "Name for variant matching $(basename -- "$file_b"):" \
    --placeholder 'e.g. gtelwifi')" || { rm -f "$fwd" "$bwd"; return 0; }
  [ -z "$name_b" ] && { rm -f "$fwd" "$bwd"; return 0; }

  local collision=0
  variant_exists "$name_a" && { warn "Variant '$name_a' already exists."; collision=1; }
  variant_exists "$name_b" && { warn "Variant '$name_b' already exists."; collision=1; }
  if [ "$collision" -eq 1 ]; then
    gum confirm "Overwrite existing variant(s)?" || { rm -f "$fwd" "$bwd"; return 0; }
  fi

  variant_save_directives "$name_a" "$bwd" >/dev/null
  variant_save_directives "$name_b" "$fwd" >/dev/null

  rm -f "$fwd" "$bwd"
  echo "✅ Saved variants: $name_a, $name_b"

  if gum confirm "Set one as the active variant for this project?"; then
    local pick
    pick="$(printf '%s\n%s\n' "$name_a" "$name_b" | gum choose --header 'Active variant:')" || return 0
    if [ -n "$pick" ]; then
      config_write KIT_BUILD_CFG_VARIANT "$pick" >/dev/null
      echo "✅ Active variant set to: $pick"
    fi
  fi
  return 0
}

# --- Interactive: pick helpers --------------------------

variant_it_pick_apply() {
  require_gum || return 1
  local -a variants=()
  mapfile -t variants < <(variant_list)
  if [ "${#variants[@]}" -eq 0 ]; then
    echo "ℹ️  No variants defined yet."
    return 0
  fi
  local pick
  pick="$(printf '%s\n' "${variants[@]}" | gum choose --header 'Apply which variant?')" || return 0
  [ -z "$pick" ] && return 0
  variant_it_apply "$pick"
}

variant_it_pick_delete() {
  require_gum || return 1
  local -a variants=()
  mapfile -t variants < <(variant_list)
  if [ "${#variants[@]}" -eq 0 ]; then
    echo "ℹ️  No variants defined yet."
    return 0
  fi
  local pick
  pick="$(printf '%s\n' "${variants[@]}" | gum choose --header 'Delete which variant?')" || return 0
  [ -z "$pick" ] && return 0
  gum confirm "Really delete variant '$pick'?" || return 0
  variant_it_delete "$pick"
}

variant_it_pick_show() {
  require_gum || return 1
  local -a variants=()
  mapfile -t variants < <(variant_list)
  if [ "${#variants[@]}" -eq 0 ]; then
    echo "ℹ️  No variants defined yet."
    return 0
  fi
  local pick
  pick="$(printf '%s\n' "${variants[@]}" | gum choose --header 'Show which variant?')" || return 0
  [ -z "$pick" ] && return 0
  variant_read_directives "$pick" | gum pager
}

# --- Interactive menu -----------------------------------

variant_it_menu() {
	
  require_gum || exit 1

  menu_begin "🔀 Build variants  (project: $PWD)"

  local active="${KIT_BUILD_CFG_VARIANT:-}"
  menu_action "Active: ${active:-(none)}" "variant_it_pick_apply" --close
  menu_action "Create from two .config files…" "variant_it_create"    --close
  menu_action "Show a variant…"                "variant_it_pick_show"
  menu_action "Delete a variant…"              "variant_it_pick_delete"
	menu_action "Detect from current .config" "INTERACTIVE=1 variant_it_detect"

  menu_action "Done" "true" --close

  menu_end variant_menu
  menu_run variant_menu
}

# --- Command dispatch -----------------------------------

cmd="${1:-}"
[ $# -gt 0 ] && shift

case "$cmd" in
  '')      variant_it_menu ;;
  list)    variant_it_list ;;
  show)    variant_it_show "$@" ;;
  apply)   variant_it_apply "$@" ;;
  create)  variant_it_create ;;
  delete)  variant_it_delete "$@" ;;
	detect)  variant_it_detect ;;
  -h|--help) usage ;;
  *)
    echo "❌ Error: unknown command: $cmd" >&2
    echo "Run 'variant-it.sh --help' for usage." >&2
    exit 1
    ;;
esac