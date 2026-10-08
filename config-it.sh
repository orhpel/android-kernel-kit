#!/usr/bin/env bash
# ========================================================
# Android Kernel Kit
#
# --- config-it.sh ---
# Interactive configuration editor for the kit. Builds a menu
# tree from config-schema.sh: one submenu per group, one entry
# per declared variable, plus guided setup actions for missing
# mandatory tools.
# ========================================================

# --- Help -----------------------------------------------

usage() {
  cat <<'EOF'
config-it.sh - edit the kit configuration

USAGE
    config-it.sh [OPTIONS]

DESCRIPTION
    Opens an interactive menu for editing kit configuration.
    Target selection is automatic:

      - inside the kit directory   -> global config ($KIT_DIR/.kit)
      - inside a project root      -> project config (<project>/.kit)
      - elsewhere                  -> search downwards, pick a project
      - no project found           -> fall back to global

    Every change is written immediately. Values equal to the
    inherited state (default, global, environment) are pruned
    from the project file, keeping it minimal.

    "Quick setup" guides through installing the optional
    external tools (Android Image Kitchen, dtbTool, toolchain).

OPTIONS
    -g, --global
        Force editing the global config. Mutually exclusive with -p.

    -p, --project
        Force editing the project config. Requires a project.

    -l, --list
        Print the effective configuration as plain text.

    -h, --help
        Show this help and exit.

EXIT STATUS
    0   success
    1   error (bad arguments, no project, cancel)
EOF
}

# --- Bootstrap ------------------------------------------

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/common.sh"
source "${KIT_DIR}/menu.sh"

config_load

# --- Argument parsing -----------------------------------

mode=""
list_only=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -g|--global)
      [ -n "$mode" ] && { echo "❌ Error: -g and -p are mutually exclusive." >&2; exit 1; }
      mode="global"; shift ;;
    -p|--project)
      [ -n "$mode" ] && { echo "❌ Error: -g and -p are mutually exclusive." >&2; exit 1; }
      mode="project"; shift ;;
    -l|--list) list_only=1; shift ;;
    -*) echo "❌ Error: Unknown option: $1" >&2; exit 1 ;;
    *)  echo "❌ Error: Unexpected argument: $1" >&2; exit 1 ;;
  esac
done

# --- Context detection ----------------------------------

CONFIG_IT_SEARCH_DEPTH=3

is_inside_kit() {
  case "$PWD/" in
    "${KIT_DIR}/"*) return 0 ;;
  esac
  return 1
}

find_projects_downwards() {
  local depth="$1" file dir
  declare -A seen=()
  while IFS= read -r file; do
    dir="$(dirname -- "$file")"
    [ -f "${dir}/Makefile" ] && [ -f "${dir}/AndroidKernel.mk" ] && seen["$dir"]=1
  done < <(find "$PWD" -maxdepth "$depth" -type f \
             \( -name Makefile -o -name AndroidKernel.mk \) 2>/dev/null)
  printf '%s\n' "${!seen[@]}" | sort
}

project_root_of() {
  local saved="$PWD" root
  cd "$1" 2>/dev/null || return 1
  root="$(find_project_marker 2>/dev/null || find_project_files 2>/dev/null || true)"
  cd "$saved" || return 1
  printf '%s\n' "$root"
}

pick_project() {
  local -a projects=()
  mapfile -t projects < <(find_projects_downwards "$CONFIG_IT_SEARCH_DEPTH")
  [ "${#projects[@]}" -eq 0 ] && return 1
  if [ "${#projects[@]}" -eq 1 ]; then
    printf '%s\n' "${projects[0]}"
    return 0
  fi
  require_gum || return 1
  local choice
  choice=$(printf '%s\n' "${projects[@]}" \
    | gum choose --header "Select a project to configure") || return 1
  printf '%s\n' "$choice"
}

TARGET_KIND=""
TARGET_ROOT=""

case "$mode" in
  global)  TARGET_KIND="global" ;;
  project)
    TARGET_ROOT="$(project_root_of "$PWD" || true)"
    [ -z "$TARGET_ROOT" ] && { echo "❌ Error: not inside a project." >&2; exit 1; }
    TARGET_KIND="project"
    ;;
  *)
    if is_inside_kit; then
      TARGET_KIND="global"
    elif TARGET_ROOT="$(project_root_of "$PWD")" && [ -n "$TARGET_ROOT" ]; then
      TARGET_KIND="project"
    elif TARGET_ROOT="$(pick_project)"; then
      TARGET_KIND="project"
    else
      TARGET_KIND="global"
    fi
    ;;
esac

target_file=""
case "$TARGET_KIND" in
  global)  target_file="${KIT_DIR}/.kit" ;;
  project) target_file="${TARGET_ROOT}/.kit" ;;
esac

# Point the loader at the intended root before config_load runs.
# _cfg_project_root walks upward from $PWD, so being in the right
# directory is what makes it find the correct .kit.
case "$TARGET_KIND" in
  global)  cd "$KIT_DIR"    || exit 1 ;;
  project) cd "$TARGET_ROOT" || exit 1 ;;
esac

config_load

# --- List mode ------------------------------------------

if [ "$list_only" -eq 1 ]; then
  printf 'Target: %s (%s)\n\n' "$TARGET_KIND" "$target_file"
  while IFS= read -r group; do
    printf '## %s\n' "$group"
    while IFS= read -r var; do
      value="${!var:-}"
      inherited="$(config_inherited_value "$var" 2>/dev/null || true)"
      mark=""
      [ "$value" != "$inherited" ] && mark=" [override]"
      printf '%-42s = %s%s\n' "$var" "$value" "$mark"
    done < <(config_list_vars "$group")
    printf '\n'
  done < <(config_list_groups)
  exit 0
fi

# --- Install actions ------------------------------------

# git_clone_or_reuse <url> <target>
#   Clones url into target, reusing an existing checkout if the
#   directory is already a git repo with the same origin.
# shellcheck disable=SC2329 # invoked via menu_action payload
git_clone_or_reuse() {
  local url="$1" target="$2"
  if [ -d "$target/.git" ]; then
    local origin
    origin="$(git -C "$target" config --get remote.origin.url 2>/dev/null || true)"
    if [ "$origin" = "$url" ]; then
      echo "ℹ️  Reusing existing checkout at $target"
      return 0
    fi
    echo "❌ Directory $target exists but points at $origin" >&2
    return 1
  fi
  if [ -e "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
    echo "❌ Directory $target exists and is not empty." >&2
    return 1
  fi
  mkdir -p "$(dirname -- "$target")"
  git clone --depth 1 "$url" "$target"
}

# ask_dir <header> <default>
#   Wrapper around gum file with a header that explains the ← key.
# shellcheck disable=SC2329 # invoked via menu_action payload
ask_dir() {
  local header="$1" default="$2"
  gum file --directory --header "${header}  (← to go up)" \
    --file "$default" 2>/dev/null
}

# shellcheck disable=SC2329 # invoked via menu_action payload
action_install_aik() {
  local default="${HOME}/Projects/Android-Image-Kitchen"
  local target
  target="$(ask_dir "Where should AIK live?" "$default")" || return 0
  [ -z "$target" ] && return 0

  if git_clone_or_reuse "https://github.com/osm0sis/Android-Image-Kitchen.git" "$target"; then
    config_write KIT_PACK_CFG_AIK_DIR "$target" >/dev/null
    echo "✅ AIK configured at $target"
  else
    echo "⚠️  AIK installation failed; config unchanged." >&2
  fi
  sleep 1
}

# shellcheck disable=SC2329 # invoked via menu_action payload
action_install_dtbtool() {
  local default="${HOME}/Projects/dtbTool-lineage17.1"
  local target
  target="$(ask_dir "Where should dtbTool live?" "$default")" || return 0
  [ -z "$target" ] && return 0

  if ! command -v make >/dev/null 2>&1 || ! command -v g++ >/dev/null 2>&1; then
    echo "❌ Missing build tools (need make and g++)." >&2
    echo "   Debian/Ubuntu:  sudo apt install build-essential" >&2
    echo "   Fedora:         sudo dnf install make gcc-c++" >&2
    echo "   Arch:           sudo pacman -S base-devel" >&2
    sleep 2
    return 0
  fi

  if git_clone_or_reuse \
      "https://github.com/LineageOS/android_system_tools_dtbtool.git" \
      "$target"; then
    if ( cd "$target" && make ); then
      config_write KIT_BUILD_CFG_DTB_TOOL "$target/dtbtool" >/dev/null
      echo "✅ dtbTool built at $target/dtbtool"
    else
      echo "⚠️  dtbTool build failed; config unchanged." >&2
    fi
  fi
  sleep 1
}

# _toolchain_pick_triplet
#   gum choose over known AOSP toolchain triplets. Prints URL + short name.
# shellcheck disable=SC2329 # invoked via menu_action payload
_toolchain_pick_triplet() {
  local entries=(
    "arm-eabi-4.8|https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-eabi-4.8|arm4.8"
    "arm-linux-androideabi-4.9|https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9|arm4.9"
  )
  local choice label rest
  local display=()
  for rest in "${entries[@]}"; do display+=("${rest%%|*}"); done
  choice=$(printf '%s\n' "${display[@]}" \
    | gum choose --header "Which toolchain?") || return 1
  for rest in "${entries[@]}"; do
    label="${rest%%|*}"
    [ "$label" = "$choice" ] && { printf '%s\n' "$rest"; return 0; }
  done
  return 1
}

# _toolchain_pick_ref <url>
#   Lists remote refs, filters to Android tags and release branches,
#   lets the user pick one. Prints the chosen ref name.
# shellcheck disable=SC2329 # invoked via menu_action payload
_toolchain_pick_ref() {
  local url="$1"
  local -a tags=() branches=()
  local ref name

  while IFS=$'\t' read -r _ name; do
    [[ "$name" =~ ^android-[0-9]+\.[0-9]+\.[0-9]+_r[0-9]+$ ]] && tags+=("$name")
  done < <(git ls-remote --tags "$url" 2>/dev/null | awk '{print $2"\t"$2}' | sed 's|refs/tags/||')

  while IFS= read -r name; do
    case "$name" in
      *-cts-release|*-security-release|*-vts-release|*-dev|master|main) continue ;;
      *-release) branches+=("$name") ;;
    esac
  done < <(git ls-remote --heads "$url" 2>/dev/null \
             | sed 's|.*refs/heads/||' | sort -u)

  # Newest android-<X.Y.Z>_r<N> first (sort by version, then _r).
  local sorted_tags=()
  if [ "${#tags[@]}" -gt 0 ]; then
    mapfile -t sorted_tags < <(printf '%s\n' "${tags[@]}" | sort -Vr)
  fi
  local sorted_branches=()
  if [ "${#branches[@]}" -gt 0 ]; then
    mapfile -t sorted_branches < <(printf '%s\n' "${branches[@]}" | sort)
  fi

  local -a menu=()
  [ "${#sorted_tags[@]}" -gt 0 ] && menu+=("── Android version tags ──" "${sorted_tags[@]}")
  [ "${#sorted_branches[@]}" -gt 0 ] && menu+=("── Release branches ──" "${sorted_branches[@]}")

  [ "${#menu[@]}" -eq 0 ] && return 1

  local picked
  picked=$(printf '%s\n' "${menu[@]}" \
    | grep -v '^──' \
    | gum choose --header "Which ref?") || return 1
  printf '%s\n' "$picked"
}

# shellcheck disable=SC2329 # invoked via menu_action payload
action_download_toolchain() {
  local pick; pick="$(_toolchain_pick_triplet)" || return 0
  local label url short
  IFS='|' read -r label url short <<<"$pick"

  local ref
  ref="$(_toolchain_pick_ref "$url")" || return 0
  [ -z "$ref" ] && return 0

  local default="${HOME}/toolchain-${short}"
  local target
  target="$(ask_dir "Install toolchain into?" "$default")" || return 0
  [ -z "$target" ] && return 0

  if ! git_clone_or_reuse "$url" "$target"; then
    sleep 2
    return 0
  fi

  if ! ( cd "$target" && git fetch --depth 1 origin "$ref" \
         && git checkout --detach FETCH_HEAD ); then
    echo "⚠️  Could not checkout $ref; leaving default branch." >&2
  fi

  # If a matching toolchain-X.sh exists, offer to activate it.
  local script_name="toolchain-${short}"
  if [ -f "${KIT_DIR}/toolchains/${script_name}.sh" ]; then
    if gum confirm "Activate toolchain '${script_name}' for all projects?"; then
      config_write KIT_COMMON_CFG_TOOLCHAIN "$script_name" >/dev/null
      echo "✅ Toolchain set to ${script_name}"
    fi
  else
    echo "ℹ️  Downloaded to $target"
    echo "   No ${script_name}.sh in ${KIT_DIR}/toolchains/ yet."
    echo "   Create it manually to enable this toolchain."
  fi
  sleep 2
}

# --- Quick setup ----------------------------------------

# shellcheck disable=SC2329 # invoked via menu_action payload
action_quick_setup() {
  gum style --border normal --padding "0 1" \
    "Quick setup installs the optional tools the kit can use.
You can skip any step; nothing will be configured without your consent."

  if gum confirm "Install Android Image Kitchen (AIK)?"; then
		action_install_aik
	fi

  if gum confirm "Does your device need a separate device-tree image at repack time? (Most Samsung devices do.)"; then
		if gum confirm "Enable automatic DTB append for this project?"; then
      config_write KIT_BUILD_CFG_AUTO_DTB_APPEND 1 "$target_file" >/dev/null
    fi
    action_install_dtbtool
  fi

  if gum confirm "Download an Android toolchain?"; then
    action_download_toolchain
  fi

  echo "✅ Quick setup done. Review the group menus to fine-tune."
  sleep 2
}

# --- Menu construction ----------------------------------

# add_config_entry <var>
#   Emits one menu_* entry for a config variable.
add_config_entry() {
  local var="$1"
  local type group desc placeholder value scope inherited mandatory
  type="$(config_meta "$var" type)"
  group="$(config_meta "$var" group)"
  desc="$(config_meta "$var" desc)"
  placeholder="$(config_meta "$var" placeholder)"
  scope="$(config_meta "$var" scope)"
  mandatory="$(config_meta "$var" mandatory 2>/dev/null || echo 0)"
  value="${!var:-}"
  inherited="$(config_inherited_value "$var" 2>/dev/null || true)"

  case "$scope" in
    global)  desc="${desc}  [scope: global]" ;;
    project) desc="${desc}  [scope: project]" ;;
    both)    desc="${desc}  [scope: both]" ;;
  esac

	if [ "$value" != "$inherited" ]; then
    desc="${desc}  [override]"
  fi

  # Type-aware "mandatory" check: for paths, verify existence; for
  # enums sourced from a directory, verify a matching file is present;
  # for strings, verify it is non-empty.
  if [ "$mandatory" = "1" ]; then
    local missing=0
    case "$type" in
      file) [ -z "$value" ] || [ ! -f "$value" ] && missing=1 ;;
      dir)  [ -z "$value" ] || [ ! -d "$value" ] && missing=1 ;;
      enum)
        if [ -n "$value" ] && [ -f "${KIT_DIR}/toolchains/${value}.sh" ]; then
          : # fine
        else
          missing=1
        fi
        ;;
      string) [ -z "$value" ] && missing=1 ;;
    esac
    [ "$missing" = "1" ] && desc="⚠️  required — ${desc}"
  fi

  local args=(--desc "$desc")

  case "$type" in
    bool)
      menu_bool "$var" "$var" "${args[@]}"
      ;;
    enum)
      local opts_str opts_dir
      local -a opts_arr=()
      opts_str="$(config_meta "$var" options)"
      opts_dir="$(config_meta "$var" options_dir)"
      if [ -n "$opts_str" ]; then
        read -r -a opts_arr <<<"$opts_str"
      elif [ -n "$opts_dir" ] && [ -d "$opts_dir" ]; then
        local opt
        for opt in "$opts_dir"/*.sh; do
          [ -f "$opt" ] || continue
          opts_arr+=("$(basename -- "$opt" .sh)")
        done
      fi
      menu_enum "$var" "$var" "${opts_arr[@]}" "${args[@]}"
      ;;
    int)
      local min max
      min="$(config_meta "$var" min)"
      max="$(config_meta "$var" max)"
      [ -n "$min" ] && args+=(--min "$min")
      [ -n "$max" ] && args+=(--max "$max")
      menu_int "$var" "$var" "${args[@]}"
      ;;
    string)
      [ -n "$placeholder" ] && args+=(--placeholder "$placeholder")
      menu_string "$var" "$var" "${args[@]}"
      ;;
    file)  args+=(--check); menu_file "$var" "$var" "${args[@]}" ;;
    dir)   args+=(--check); menu_dir  "$var" "$var" "${args[@]}" ;;
  esac
}

define_group_menu() {
  local group="$1" name="$2"
  local header
  case "$TARGET_KIND" in
    global)  header="⚙  Global — ${group}" ;;
    project) header="⚙  Project (${TARGET_ROOT##*/}) — ${group}" ;;
  esac
  menu_begin "$header"
  local var
  while IFS= read -r var; do
    add_config_entry "$var"
  done < <(config_list_vars "$group")

	case "$group" in
    Pack)
      menu_action "Install Android Image Kitchen…" "action_install_aik"
      ;;
    Build)
      menu_action "Install dtbTool…"               "action_install_dtbtool"
      if [ "$TARGET_KIND" = "project" ]; then
        menu_action "Manage build variants…" "'${KIT_DIR}/variant-it.sh'"
      fi
      ;;
    General)
      menu_action "Download toolchain…"            "action_download_toolchain"
      ;;
  esac

  menu_end "$name"
}

define_root_menu() {
  local header
  case "$TARGET_KIND" in
    global)  header="⚙  Kit configuration (global)" ;;
    project) header="⚙  Kit configuration (project: ${TARGET_ROOT##*/})" ;;
  esac

  menu_begin "$header"

  menu_action "Quick setup" "action_quick_setup"

  local group idx=0 name
  while IFS= read -r group; do
    name="cfg_group_${idx}"
    menu_submenu "$group" "$name"
    idx=$((idx + 1))
  done < <(config_list_groups)

  menu_action "Show target file" "printf '%s\n' '${target_file}'"
  menu_action "Done" "true" --close

  menu_end "cfg_root"
}

# --- Reconciliation -------------------------------------

# write_back_changes <group>
#   Persist values that changed via menu (menu.sh writes only to
#   shell variables). Called after the main menu returns.
#   The edit target (TARGET_KIND) determinates where the value goes,
#   regardless of the variable's own scope.
write_back_changes() {
  local group="$1" var current persisted scope
  while IFS= read -r var; do
    current="${!var:-}"
    persisted="$(_cfg_read_value "$target_file" "$var")"
    scope="$(config_meta "$var" scope)"

    # Skip variables that don't apply to this edit target at all.
    # A scope=global var can't be set in a project file; a scope=project
    # var can't be set in the global file.
    case "$TARGET_KIND:$scope" in
      global:global|global:both|project:project|project:both) ;;
      *) continue ;;
    esac

    if [ "$current" != "$persisted" ]; then
      config_write "$var" "$current" "$target_file" >/dev/null \
        || warn "Failed to persist $var"
    fi
  done < <(config_list_vars "$group")
}

# --- NerdFont onboarding --------------------------------

# Ask once whether the user's terminal supports NerdFonts. The
# answer selects the pipeline progress style (NerdFont glyphs or
# plain ASCII arrows). The STATE flag lives in the global .kit, so
# the question is asked exactly once per kit installation.
if [ "${KIT_COMMON_STATE_NERDFONT_ASKED:-0}" != "1" ]; then
  if gum confirm "Do you use a NerdFont-compatible terminal?"; then
    config_write KIT_COMMON_CFG_NERDFONT 1 >/dev/null
  fi
  config_state_set KIT_COMMON_STATE_NERDFONT_ASKED 1 >/dev/null
fi

# --- Run ------------------------------------------------

require_gum || exit 1

local_group_idx=0
while IFS= read -r group; do
  define_group_menu "$group" "cfg_group_${local_group_idx}"
  local_group_idx=$((local_group_idx + 1))
done < <(config_list_groups)

define_root_menu
menu_run cfg_root || exit 1

while IFS= read -r group; do
  write_back_changes "$group"
done < <(config_list_groups)

exit 0