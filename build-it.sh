#!/usr/bin/env bash
# ========================================================
# Android Kernel Kit
#
# --- build-it.sh ---
# Starts the make process of a new kernel and shows an
# approximate progress bar based on the amount of output
# lines (current vs. last successful build).
# If tmux is available and the shell is interactive, the build runs
# inside a tmux session with a live side pane (see stream.sh).
# KIT_NO_TMUX=1 or -N/--no-tmux disables this.
# ========================================================
# Progress bar (optional): uses tqdm if available, otherwise
# falls back to pv. Without either, the build runs without
# a progress bar.
#   tqdm -> https://github.com/tqdm/tqdm
#   pv   -> https://github.com/icetee/pv
#

# --- Help -----------------------------------------------

usage() {
  cat <<'EOF'
build-it.sh - Start a new kernel build with the given arguments.

USAGE
    build-it.sh [OPTIONS] [--] [MAKE_ARGS...]

DESCRIPTION
    Calls 'make' with the given arguments and assigns the build
    a new, monotonically increasing build number.

    The build number is appended to LOCALVERSION, so it becomes
    visible in dmesg during boot and can be used to identify the
    binary that is currently running on the device.

    build-it.sh only handles kernel builds. Non-build targets such
    as 'clean', 'mrproper', '*config', 'modules', 'dtbs_install'
    or 'help' are rejected: run make directly for those.

    At least one kernel image target must be present:
        zImage, zImage-dtb, Image, Image.gz, Image.gz-dtb, uImage

    If the chosen target does not contain an appended device tree
    (i.e. its name does not end in 'dtb'), a separate device-tree
    image is generated from a dts directory via dtbTool and stored
    as BUILD_DIR/boot-dt.img. The dts directory is taken from
    --dts-dir or, if KIT_BUILD_CFG_AUTO_DTB_APPEND=1, from
    KIT_BUILD_CFG_DTB_DIR in the kit configuration.

    If --output is given, the resulting image is copied to that
    directory after a successful build:
        zImage        -> zImage-b<N>
        zImage-dtb    -> zImage-dtb-b<N>
        Image.gz-dtb  -> Image.gz-dtb-b<N>
        Image.gz      -> Image.gz-b<N>
        Image         -> Image-b<N>
        uImage        -> uImage-b<N>

    If KIT_BUILD_CFG_AUTO_ARCHIVE is enabled (see common.sh), a copy of the
    built kernel image, boot-dt.img (if generated) and the used
    .config are stored in KIT_BUILD_CFG_ARCHIVE_DIR/<LOCALVERSION>.
    This is independent of --output and can be suppressed per run
    with --no-archive.

    If --repack is given, the freshly built kernel is additionally
    handed over to pack-it.sh to be packed into a boot image.
    The optional --boot-image and --flash options are only passed
    through to pack-it.sh and have no effect on the build itself.

		The script will call colormake instead of make, if colormake
		is available.

ARGUMENTS
    MAKE_ARGS       Kernel image targets and variables passed
                    to make.
                    Defaults to: "zImage dtbs"

OPTIONS
    -l, --localversion STRING
        Appended to the existing LOCALVERSION. The base value comes
        from KIT_BUILD_OPT_LOCALVERSION in the kit configuration.
        May be used multiple times; values accumulate in the given
        order.

    -N, --no-tmux
        Do not launch the build inside a tmux session. Overrides the
        automatic tmux re-exec and behaves like setting
        KIT_COMMON_OPT_NO_TMUX=1 in the kit configuration.

    -o, --output PATH
        Directory to which the new kernel image is copied after
        a successful build. Created if missing. Files with the
        same name are overwritten.

    -s, --silent
        Suppress progress output. The full build log is still
        captured and printed on error.

    -v, --verbose
        Show the raw output of called tools (make, dtbTool,
        pack-it.sh, ...) on the terminal. Without this flag,
        tool chatter only lands in the log; this script's own
        status messages remain visible either way.

    -c, --clean
        Run clean-it.sh before starting the build. The silent
        and verbose flags are forwarded to clean-it.sh.

    -A, --no-archive
        Do not create an archive entry even if KIT_BUILD_CFG_AUTO_ARCHIVE
        is enabled in the kit configuration.

    -d, --dts-dir PATH
        Device-tree source directory. If the chosen kernel image
        target does not contain an appended device tree, a
        boot-dt.img is generated from this directory via dtbTool.
        Falls back to KIT_BUILD_CFG_DTB_DIR, then to <BUILD_DIR>/dts
        when KIT_BUILD_CFG_AUTO_DTB_APPEND=1.

    -r, --repack
        After a successful build, invoke pack-it.sh with the
        freshly built kernel image.

    -b, --boot-image PATH
        Source boot image to hand over to pack-it.sh.
        Only effective together with --repack.

    -f, --flash
        Instruct pack-it.sh to flash the resulting boot image
        (via flash-it.sh) after repacking.
        Only effective together with --repack.

    -h, --help
        Show this help and exit.

EXAMPLES
    build-it.sh
        Builds the default targets (zImage dtbs).

    build-it.sh -l mytest
        Builds the default targets and appends '-mytest' to
        LOCALVERSION.

    build-it.sh -N zImage
        Builds zImage without launching a tmux session.

    build-it.sh -o /tmp/out zImage-dtb
        Builds zImage-dtb and copies it to /tmp/out as
        'zImage-dtb-b<N>'.

    build-it.sh -v -d arch/arm/boot/dts zImage
        Builds zImage verbosely and generates boot-dt.img.

    build-it.sh -r -b boot.img -d arch/arm/boot/dts zImage
        Builds zImage, generates boot-dt.img, and repacks the
        result into boot.img.

    build-it.sh -c zImage
        Cleans the build environment, then builds zImage.

    build-it.sh -A zImage
        Builds zImage without creating an archive entry, even
        if KIT_BUILD_CFG_AUTO_ARCHIVE is enabled.

EXIT STATUS
    0   success
    1   error (invalid arguments, build failure, IO error)
EOF
}

# --- Save original args for logging ---------------------

orig_args=("$@")

# --- Defaults -------------------------------------------

silence="${KIT_SILENT:-0}"
verbose=0
output=""
variant_override=""

do_repack=0
do_flash=0
do_clean=0
no_archive=0
boot_image=""

dtb_dir=""

make_args=()
read -r -a default_args <<<"${KIT_BUILD_CFG_DEFAULT_TARGETS:-zImage dtbs}"

tqdm_args=(--null --unit lines --desc Building)
pv_args=(--line-mode --name Building)

non_build_targets=(
  clean mrproper distclean
  menuconfig nconfig xconfig gconfig oldconfig olddefconfig
  defconfig savedefconfig
  modules modules_install
  dtbs_install
  help
)

declare -A image_targets=(
  ["zImage"]="zImage"
  ["zImage-dtb"]="zImage-dtb"
  ["Image.gz-dtb"]="Image.gz-dtb"
  ["Image.gz"]="Image.gz"
  ["Image"]="Image"
  ["uImage"]="uImage"
)

# --- Common helpers -------------------------------------
# shellcheck source=SCRIPTDIR/common.sh

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/common.sh"
source "${KIT_DIR}/stream.sh"
source "${KIT_DIR}/variant.sh"

# --help must work outside a project and before any tmux re-exec.
for _arg in "${orig_args[@]}"; do
  case "$_arg" in
    -h|--help) usage; exit 0 ;;
    --) break ;;
  esac
done
unset _arg

# Expand clustered short options first so the pre-scan below sees
# them individually (e.g. -cs → -c -s).
expanded=()
expand_clustered_options expanded "scArfhvN" "lobdV" "$@"
set -- "${expanded[@]}"

# Pre-scan for --no-tmux / -N and --silent / -s. Must happen before
# stream_ensure_tmux, since the re-exec would otherwise replace the
# process before the full argument parser could honor these flags.
# KIT_SILENT is exported so the whole chain (tmux re-exec, clean-it,
# pack-it, flash-it) stays silent once set.
for _arg in "$@"; do
  case "$_arg" in
    --no-tmux|-N) export KIT_COMMON_OPT_NO_TMUX=1 ;;
    -s|--silent)  export KIT_SILENT=1 ;;
    --) break ;;
  esac
done

config_load

# --- Pipeline progress ----------------------------------
# Initialise the chain before the tmux re-exec so the inner
# process inherits the exported state. Only start a fresh chain
# when we are not already part of one.
if [ "${KIT_COMMON_CFG_NERDFONT:-0}" = "1" ] || [ -n "${KIT_PIPELINE_STATE:-}" ]; then
  if [ -z "${KIT_PIPELINE_STATE:-}" ]; then
    export KIT_PIPELINE_STATE="clean-it=pending,build-it=pending,pack-it=pending,flash-it=pending"
  fi
fi

# Verify we're inside a kernel project before launching tmux — otherwise
# the inner re-exec would fail and hide the error inside a tmux session.
cd_project_root || exit 1

stream_ensure_tmux "${BASH_SOURCE[0]}" "${orig_args[@]}" || true
log_init "$(basename -- "$0")" "${orig_args[@]}"
load_toolchain || exit 1

lversion="${KIT_BUILD_OPT_LOCALVERSION:-}"

# --- Argument parsing -----------------------------------

while [ $# -gt 0 ]; do
  case "${1}" in
  -h | --help)
    usage
    exit 0
    ;;
  -v | --verbose)
    verbose=1
    shift
    ;;
  -l | --localversion)
    if [ -z "${2:-}" ]; then
      echo "❌ Error: ${1} requires a version string." >&2
      exit 1
    fi
    lversion="${lversion:+${lversion}-}${2}"
    shift 2
    ;;
  -V | --variant)
    if [ -z "${2:-}" ]; then
      echo "❌ Error: ${1} requires a variant name." >&2
      exit 1
    fi
    variant_override="${2}"
    shift 2
    ;;		
  -o | --output)
    if [ -z "${2:-}" ]; then
      echo "❌ Error: ${1} requires a path." >&2
      exit 1
    fi
    output="${2}"
    shift 2
    ;;
  -s | --silent)
    silence=1
    export KIT_SILENT=1
    shift
    ;;
  -c | --clean)
    do_clean=1
    shift
    ;;
  -A | --no-archive)
    no_archive=1
    shift
    ;;
  -d | --dts-dir)
    if [ -z "${2:-}" ]; then
      echo "❌ Error: ${1} requires a path to the device-tree directory." >&2
      exit 1
    fi
    dtb_dir="${2}"
    shift 2
    ;;
	-N | --no-tmux)
    # Handled in the pre-scan; consume so the parser does not reject it.
    shift
    ;;
  -r | --repack)
    do_repack=1
    shift
    ;;
  -b | --boot-image)
    if [ -z "${2:-}" ]; then
      echo "❌ Error: ${1} requires a path to a boot image." >&2
      exit 1
    fi
    boot_image="${2}"
    shift 2
    ;;
  -f | --flash)
    do_flash=1
    shift
    ;;
  --)
    shift
    break
    ;;
  -*)
    echo "❌ Error: Unknown option: ${1}" >&2
    exit 1
    ;;
  *)
    make_args+=("${1}")
    shift
    ;;
  esac
done

if [ $# -gt 0 ]; then
  make_args+=("$@")
fi

if [ "${#make_args[@]}" -eq 0 ]; then
  make_args=("${default_args[@]}")
fi

# --- Effective verbosity --------------------------------
# shellcheck disable=SC2034  # read by run_tool in common.sh
VERBOSE=$verbose
# shellcheck disable=SC2034  # read by run_tool in common.sh
[ "${silence}" -eq 1 ] && VERBOSE=0

# --- Guard against unused repack options ----------------

if [ "${do_repack}" -eq 0 ]; then
  if [ -n "${boot_image}" ]; then
    warn "--boot-image has no effect without --repack; ignoring."
    boot_image=""
  fi
  if [ "${do_flash}" -eq 1 ]; then
    warn "--flash has no effect without --repack; ignoring."
    do_flash=0
  fi
fi

# --- Guard against user-supplied LOCALVERSION -----------

for arg in "${make_args[@]}"; do
  if [[ "${arg}" == LOCALVERSION=* ]]; then
    user_lversion="${arg#LOCALVERSION=}"
    if [[ -n "${user_lversion}" ]]; then
      lversion="${lversion:+${lversion}-}${user_lversion}"
    fi
  fi
done

# --- Reject non-build targets ---------------------------

rejected=()
for arg in "${make_args[@]}"; do
  for tgt in "${non_build_targets[@]}"; do
    if [ "${arg}" = "${tgt}" ]; then
      rejected+=("${arg}")
      break
    fi
  done
done

has_image=0
for arg in "${make_args[@]}"; do
  if [ -n "${image_targets[${arg}]+x}" ]; then
    has_image=1
    break
  fi
done

if [ "${#rejected[@]}" -gt 0 ] || [ "${has_image}" -eq 0 ]; then
  printf -v cmd '%q ' "${make_args[@]}"
  echo "❌ Error: The given arguments do not produce a kernel image." >&2
  if [ "${#rejected[@]}" -gt 0 ]; then
    echo "   Unsupported target(s): ${rejected[*]}" >&2
  fi
  echo "   build-it.sh is intended for kernel builds only;" >&2
  echo "   interactive and maintenance targets are not supported." >&2
  echo "👉  Please run the following command directly instead:" >&2
  echo "       make ${cmd% }" >&2
  exit 1
fi

# --- Determine which artifact to copy -------------------

copy_src=""
for arg in "${make_args[@]}"; do
  if [ -n "${image_targets[${arg}]+x}" ]; then
    copy_src="${image_targets[${arg}]}"
    break
  fi
done

# --- Progress tool detection ---------------------------

progress_tool=""
if command -v tqdm >/dev/null 2>&1; then
  progress_tool="tqdm"
elif command -v pv >/dev/null 2>&1; then
  progress_tool="pv"
fi

if [ -z "${progress_tool}" ] && ! stream_available \
   && [ "${silence}" -eq 0 ] && [ "${VERBOSE}" -eq 0 ]; then
  warn "Neither 'tqdm' nor 'pv' found; continuing without a progress bar."
  echo "   Install one of them, or run inside tmux for live streaming:" >&2
  echo "     - tqdm: pip install tqdm   (https://github.com/tqdm/tqdm)" >&2
  echo "     - pv:   apt install pv     (https://github.com/icetee/pv)" >&2
fi

prev_lines="${KIT_BUILD_STATE_REF_LINES:-0}"
if [[ "${prev_lines}" =~ ^[0-9]+$ ]] && [ "${prev_lines}" -gt 0 ]; then
  tqdm_args+=(--total "${prev_lines}")
fi

# --- Device-tree preflight ------------------------------

case "$(basename -- "${copy_src}")" in
  *dtb) kernel_has_dtb=1 ;;
  *)    kernel_has_dtb=0 ;;
esac

if [ "$kernel_has_dtb" -eq 1 ]; then
  if [ -n "$dtb_dir" ]; then
    warn "Kernel target '${copy_src}' already contains an appended device tree; ignoring --dts-dir '${dtb_dir}'."
    dtb_dir=""
  fi
elif [ -z "$dtb_dir" ] && [ "${KIT_BUILD_CFG_AUTO_DTB_APPEND:-0}" -eq 1 ]; then
  if [ -n "${KIT_BUILD_CFG_DTB_DIR:-}" ]; then
    dtb_dir="${KIT_BUILD_CFG_DTB_DIR}"
  elif [ -n "${BUILD_DIR:-}" ]; then
    dtb_dir="${BUILD_DIR}/dts"
  else
    warn "Cannot determine default DTB directory: BUILD_DIR is not set."
  fi
fi

if [ -n "$dtb_dir" ]; then
  if [ ! -d "$dtb_dir" ]; then
    echo "❌ Error: Device-tree directory not found: ${dtb_dir}" >&2
    exit 1
  fi
  if ! command -v "${KIT_BUILD_CFG_DTB_TOOL}" >/dev/null 2>&1; then
    echo "❌ Error: dtbTool not found at ${KIT_BUILD_CFG_DTB_TOOL}" >&2
    echo " 👉 Please use the official LineageOS version, depending on your ROM version:" >&2
    echo " 🌍 https://github.com/LineageOS/android_system_tools_dtbtool/tree/lineage-17.1" >&2
    exit 1
  fi
fi

# --- Colormake detection --------------------------------

make_cmd="make"
if command -v colormake >/dev/null 2>&1; then
	make_cmd="colormake"
fi

# --- Optional pre-build cleanup -------------------------

if [ "${do_clean}" -eq 1 ]; then
  clean_args=()
  [ "${silence}" -eq 1 ] && clean_args+=(--silent)
  [ "${verbose}" -eq 1 ] && clean_args+=(--verbose)

  if [ -z "${KIT_DIR:-}" ]; then
    echo "❌ Error: KIT_DIR is not set; cannot locate clean-it.sh." >&2
    exit 1
  fi

  powerline_emit clean-it
	[ "${silence}" -eq 1 ] || echo "🧹 Running cleanup before build ..."
  if ! "${KIT_DIR}/clean-it.sh" "${clean_args[@]}"; then
    echo "❌ Error: clean-it.sh failed." >&2
    exit 1
  fi
fi

# --- Effective variant ----------------------------------
# The project's active variant (KIT_BUILD_CFG_VARIANT) or a -V
# CLI override wins over the project's active variant.
effective_variant="${variant_override:-${KIT_BUILD_CFG_VARIANT:-}}"

# --- Build number ---------------------------------------

BUILDNO="${KIT_BUILD_STATE_BUILDNO:-0}"
if [[ ! "$BUILDNO" =~ ^[0-9]+$ ]]; then
  echo "❌ Error: Invalid build number '${BUILDNO:-<empty>}'." >&2
  exit 1
fi
BUILDNO=$((BUILDNO + 1))

# --- Optionally tag LOCALVERSION with the variant -------
# Opt-in via KIT_BUILD_CFG_VARIANT_TAG. The variant sits between
# user content and the build number:
#   <user suffix>-<variant>-build<N>
if [ "${KIT_BUILD_CFG_VARIANT_TAG:-0}" = "1" ] && [ -n "$effective_variant" ]; then
  lversion="${lversion:+${lversion}-}${effective_variant}"
fi

final_lversion="${lversion:+${lversion}-}build${BUILDNO}"

# --- Apply variant (if any) -----------------------------
# override is applied to .config before make runs. Idempotent.
if [ -n "$effective_variant" ]; then
  if ! variant_exists "$effective_variant"; then
    echo "❌ Error: variant '$effective_variant' not found." >&2
    echo "   Defined variants:" >&2
    variant_list | sed 's/^/     - /' >&2
    exit 1
  fi
  [ "${silence}" -eq 0 ] && echo "🔀 Applying variant: ${effective_variant}"
	# --- Variant consistency check (opt-in) -----------------
	# Only runs if the user enabled KIT_BUILD_CFG_VARIANT_CHECK. Warns
	# when the current .config does not match any defined variant —
	# which means it carries local edits that will survive the patch.
	if [ "${KIT_BUILD_CFG_VARIANT_CHECK:-0}" = "1" ]; then
		_variant_matches=()
		mapfile -t _variant_matches < <(variant_detect .config 2>/dev/null)
		if [ "${#_variant_matches[@]}" -eq 0 ]; then
			warn ".config does not match any variant — local edits will be preserved across the patch."
		fi
	fi
  variant_apply "$effective_variant" ".config" || {
    echo "❌ Error: failed to apply variant '$effective_variant'." >&2
    exit 1
  }
  variant_normalize || warn "Config normalization failed; continuing with patched .config."
fi

# --- Run ------------------------------------------------

make_cmd=(
  "$make_cmd"
  CC="$CC"
  LD="$LD"
  -j"$(nproc)"
  "${make_args[@]}"
  LOCALVERSION="${final_lversion}"
)
powerline_emit build-it

if [ "${silence}" -eq 0 ]; then
  echo "Starting kernel build #${BUILDNO}"
  printf '🐚 ' >&2
  print_cmd "${make_cmd[@]}" >&2
fi

if [ "${silence}" -eq 1 ]; then
  # Silent: no terminal output at all, full capture in log.
  "${make_cmd[@]}" >"${TEMP_LOG}" 2>&1
  make_status=$?
  [ -e /dev/fd/3 ] && cat "${TEMP_LOG}" >&3 2>/dev/null
elif [ "${VERBOSE}" -eq 1 ]; then
  # Verbose: raw make output on terminal (and log via tee chain).
  "${make_cmd[@]}" 2>&1 | tee "${TEMP_LOG}"
  make_status="${PIPESTATUS[0]}"
elif stream_available; then
  # Streaming: live output in a tmux pane, mirrored to the session
  # log and captured in TEMP_LOG for post-build error extraction.
  : > "${TEMP_LOG}"
  STREAM_EXTRA_LOG="${TEMP_LOG}" \
    ui_stream "Building kernel #${BUILDNO}" "${make_cmd[@]}"
  make_status=$?
elif [ "${progress_tool}" = "tqdm" ]; then
  # Fallback: progress bar only; tool output goes straight to log.
  "${make_cmd[@]}" 2>&1 | tee "${TEMP_LOG}" /dev/fd/3 | tqdm "${tqdm_args[@]}" >/dev/null 2>/dev/tty
  make_status="${PIPESTATUS[0]}"
elif [ "${progress_tool}" = "pv" ]; then
  "${make_cmd[@]}" 2>&1 | tee "${TEMP_LOG}" /dev/fd/3 | pv "${pv_args[@]}" >/dev/null 2>/dev/tty
  make_status="${PIPESTATUS[0]}"
else
  "${make_cmd[@]}" >"${TEMP_LOG}" 2>&1
  make_status=$?
  [ -e /dev/fd/3 ] && cat "${TEMP_LOG}" >&3 2>/dev/null
fi

# --- Post-build -----------------------------------------

if [ "${make_status}" -ne 0 ]; then
  echo "❌ Error: Failed to build kernel." >&2
  rm -f "${TEMP_LOG}"
  exit 1
fi

build_lines=$(wc -l <"${TEMP_LOG}")
rm -f "${TEMP_LOG}"

config_state_set KIT_BUILD_STATE_REF_LINES "$build_lines" >/dev/null
config_state_set KIT_BUILD_STATE_BUILDNO   "$BUILDNO"     >/dev/null

# --- Generate boot-dt.img (if applicable) ---------------

boot_dt_img="${BUILD_DIR}/boot-dt.img"
rm -f "${boot_dt_img}"

if [ -n "$dtb_dir" ]; then
  [ "${silence}" -eq 0 ] && echo "🌲 Generating boot-dt.img from ${dtb_dir}"
  if ! run_tool "${KIT_BUILD_CFG_DTB_TOOL}" -o "${boot_dt_img}" -s 2048 "${dtb_dir}"; then
    rm -f "${boot_dt_img}"
    echo "❌ Error: dtbTool failed to produce boot-dt.img." >&2
    exit 1
  fi
fi

# --- Copy the artifact, if requested --------------------

if [ -n "${output}" ]; then
  src_path="${BUILD_DIR}/${copy_src}"
  if [ -f "${src_path}" ]; then
    mkdir -p "${output}"
    dest_name="${copy_src}-b${BUILDNO}"
    cp "${src_path}" "${output}/${dest_name}"
    if [ "${silence}" -eq 0 ]; then
      echo "📦 Copied ${copy_src} to ${output}/${dest_name}"
    fi
  else
    warn "Expected image '${src_path}' not found; nothing copied."
  fi
fi

# --- Archive the build ----------------------------------

if [ "${KIT_BUILD_CFG_AUTO_ARCHIVE:-0}" -eq 1 ] && [ "${no_archive}" -eq 0 ]; then
  archive_subdir="${KIT_BUILD_CFG_ARCHIVE_DIR:-build_archive}/${final_lversion}"

  if [ -e "${archive_subdir}" ]; then
    warn "Archive entry already exists: ${archive_subdir}; not created."
  elif ! mkdir -p "${archive_subdir}" 2>/dev/null; then
    warn "Could not create archive directory: ${archive_subdir}"
  else
    archive_src="${BUILD_DIR}/${copy_src}"
    if [ -f "${archive_src}" ]; then
      cp "${archive_src}" "${archive_subdir}/${copy_src}"
      [ "${silence}" -eq 0 ] && echo "🗄️  Archived ${copy_src} → ${archive_subdir}/"
    else
      warn "Kernel image '${archive_src}' not found; not archived."
    fi

    if [ -f "${boot_dt_img}" ]; then
      cp "${boot_dt_img}" "${archive_subdir}/boot-dt.img"
      [ "${silence}" -eq 0 ] && echo "🗄️  Archived boot-dt.img → ${archive_subdir}/"
    fi

		if [ -f "$PWD/.config" ]; then
      cp "$PWD/.config" "${archive_subdir}/config"
      [ "${silence}" -eq 0 ] && echo "🗄️  Archived .config → ${archive_subdir}/"
    fi
  fi
fi

if [ "${silence}" -eq 0 ]; then
  echo "🧩 Kernel build #${BUILDNO} finished successfully."
fi

# --- Repack, if requested -------------------------------

if [ "${do_repack}" -eq 1 ]; then
  repack_kernel="${BUILD_DIR}/${copy_src}"
  repack_args=()
  [ -n "${boot_image}" ] && repack_args+=(--boot-image "${boot_image}")
  [ "${do_flash}" -eq 1 ] && repack_args+=(--flash)
  [ -f "${boot_dt_img}" ] && repack_args+=(--dtb-image "${boot_dt_img}")
  [ "${verbose}" -eq 1 ] && repack_args+=(--verbose)
  [ "${silence}" -eq 1 ] && repack_args+=(--silent)
  repack_args+=("${repack_kernel}")

  if [ "${silence}" -eq 0 ]; then
    echo "🔁 Invoking pack-it.sh (kernel: ${repack_kernel})"
  fi

  if ! "${KIT_DIR}/pack-it.sh" "${repack_args[@]}"; then
    echo "❌ Error: pack-it.sh failed." >&2
    exit 1
  fi
fi

exit 0
