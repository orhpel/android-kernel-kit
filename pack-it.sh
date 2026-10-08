#!/usr/bin/env bash
# ========================================================
# Android Kernel Kit
#
# pack-it.sh
# Repacks a boot image using AIK or magiskboot. Consumes
# ready-made kernel and device-tree images produced by
# build-it.sh. Optionally overlays files into the ramdisk.
#
# ========================================================

# --- Help -----------------------------------------------

usage() {
	cat <<'EOF'
pack-it.sh - Repack a kernel into a boot image.

USAGE
    pack-it.sh [OPTIONS] [--] [KERNEL] [BOOT_IMG]

DESCRIPTION
    Unpacks a boot image with AIK or magiskboot, replaces its
    kernel with the given kernel image, optionally replaces the
    appended device tree with a ready-made boot-dt.img, applies
    an optional ramdisk overlay, and repacks everything into a
    new boot image.

    This script does NOT compile device trees. A ready-made
    device-tree image must be supplied via --dtb-image or be
    found at BUILD_DIR/boot-dt.img. If neither is available,
    the device tree from the source boot image is kept.

    If no KERNEL is given, the script searches the build directory
    for one of:
        zImage-dtb, Image.gz-dtb, zImage, Image.gz, Image, uImage

    Device-tree handling:
      - If the kernel filename ends in "dtb" (e.g. zImage-dtb,
        Image.gz-dtb), the device tree is assumed to be already
        appended. Any --dtb-image is ignored and the old device
        tree inside the unpacked image is removed before repacking.
      - Otherwise, if --dtb-image is given (or BUILD_DIR/boot-dt.img
        exists), it replaces the existing device tree.
      - Otherwise, the existing device tree from the source boot
        image is kept and a warning is printed.

OPTIONS
    -a, --aik-tool
        Use Android Image Kitchen to unpack/repack (default).

    -m, --magisk-tool
        Use magiskboot to unpack/repack. The binary must be
        available in PATH.

    -b, --boot-image PATH
        Source boot image to unpack.
        Default: KIT_PACK_CFG_DEFAULT_BOOT_IMAGE from the kit
        configuration (boot.img).

    -t, --dtb-image PATH
        Ready-made device-tree image (boot-dt.img) to append to
        the repacked boot image. Ignored if the kernel already
        contains an appended device tree.
        Fallback: BUILD_DIR/boot-dt.img, if present.

    -r, --ramdisk-add DIR
        Overlay the contents of DIR into the ramdisk. The
        directory mirrors the ramdisk layout, e.g.:
            overlay/etc/fstab.sc8830
        overwrites /etc/fstab.sc8830 in the ramdisk. Existing
        files are replaced silently; directories are created
        as needed. Only regular files are supported; symlinks
        and special files abort the run with an error.

    --ramdisk-rm PATH
        Remove PATH (relative to the ramdisk root) from the
        ramdisk before repacking. May be given multiple times.
        Missing entries produce a warning, not an error.

    --ramdisk-strict
        When used with --ramdisk-add, warn about every overlay
        file that did not already exist in the original
        ramdisk. Without this flag, additions are silent.

    -o, --output PATH
        Where to place the final boot image.
        If PATH is an existing directory or ends with a slash,
        the image is stored as <PATH>/boot.img. Otherwise PATH
        is used as the target filename directly.
        Without this option, the image stays in the tool's
        work directory (AIK: image-new.img, magisk: new-boot.img).

    -v, --verbose
        Show the raw output of called tools (AIK, magiskboot,
        flash-it.sh, ...) on the terminal. Without this flag,
        tool chatter only lands in the log; this script's own
        status messages remain visible either way.

    -f, --flash
        After successfully producing the new boot image, invoke
        flash-it.sh to flash it to a connected device.

    -s, --silent
        Suppress info output (status echos). Warnings and errors
        still print. Also set when KIT_SILENT=1 is present in the
        environment (propagated from build-it.sh -s).				

    -h, --help
        Show this help and exit.

ARGUMENTS
    KERNEL       Path to the kernel image (e.g. zImage,
                 zImage-dtb, Image.gz-dtb, Image.gz, Image,
                 uImage). Optional.
    BOOT_IMG     Source boot image (same as --boot-image).
                 Optional.

    If both positionals are given, the order can be inferred
    when the file types are detectable (an Android boot image
    is recognised as such; anything else is treated as kernel).

EXAMPLES
    pack-it.sh
        Repacks using the latest kernel from the build dir.

    pack-it.sh -m -o out/boot.img
        Repacks with magiskboot and writes the result to out/boot.img.

    pack-it.sh -r ./overlay
        Overlays ./overlay into the ramdisk before repacking.

    pack-it.sh -r ./overlay --ramdisk-rm etc/init.d/99foo
        Overlays files and removes one ramdisk entry.

    pack-it.sh -t build/arch/arm/boot/boot-dt.img zImage boot.img
        Repacks zImage into boot.img using the given boot-dt.img.

    pack-it.sh -f
        Repacks and flashes the resulting boot image.

EXIT STATUS
    0   success
    1   error (invalid arguments, file not found, IO error)
EOF
}


# --- Save original args ---------------------------------

orig_args=("$@")

# Load common kit
# shellcheck source=common.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/common.sh"

# --help must work outside a project too.
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

cd_project_root || exit 1

# Resolve kit configuration (schema defaults, .kit files, environment).
config_load

# --- Defaults & setup -----------------------------------

boot_source="${KIT_PACK_CFG_DEFAULT_BOOT_IMAGE:-boot.img}"
boot_source_set=0
boot_target=""
kernel_path=""
dtb_image=""
output=""
remove_old_dtb=0
flash=0
verbose=0
silent="${KIT_SILENT:-0}"
tool="${KIT_PACK_CFG_REPACK_TOOL:-aik}"

ramdisk_add=""
ramdisk_rm=()
ramdisk_strict=0

MAGISK_WORK_DIR="$PWD/.magisk_work"

# --- Expand clustered short options ---------------------

expanded=()
expand_clustered_options expanded "afhmv" "btor" "$@"
set -- "${expanded[@]}"

# --- Argument parsing -----------------------------------

positionals=()

while [ $# -gt 0 ]; do
	case "$1" in
	-a | --aik-tool)
		tool="aik"
		shift
		;;
	-m | --magisk-tool)
		tool="magisk"
		shift
		;;
	-v | --verbose)
		verbose=1
		shift
		;;
	-b | --boot-image)
		if [ -z "${2:-}" ]; then
			echo "❌ Error: $1 requires a path to a boot image." >&2
			exit 1
		fi
		boot_source="${2}"
		boot_source_set=1
		shift 2
		;;
	-t | --dtb-image)
		if [ -z "${2:-}" ]; then
			echo "❌ Error: $1 requires a path to a device-tree image." >&2
			exit 1
		fi
		dtb_image="${2}"
		shift 2
		;;
	-r | --ramdisk-add)
		if [ -z "${2:-}" ]; then
			echo "❌ Error: $1 requires a directory." >&2
			exit 1
		fi
		ramdisk_add="${2}"
		shift 2
		;;
	--ramdisk-rm)
		if [ -z "${2:-}" ]; then
			echo "❌ Error: $1 requires a ramdisk path." >&2
			exit 1
		fi
		ramdisk_rm+=("${2}")
		shift 2
		;;
	--ramdisk-strict)
		ramdisk_strict=1
		shift
		;;
	-f | --flash)
		flash=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	-o | --output)
		if [ -z "${2:-}" ]; then
			echo "❌ Error: $1 requires a path." >&2
			exit 1
		fi
		output="${2}"
		shift 2
		;;
  -s | --silent)
    silent=1
    export KIT_SILENT=1
    shift
    ;;		
	--)
		shift
		break
		;;
	-*)
		echo "❌ Error: Unknown option: $1" >&2
		exit 1
		;;
	*)
		positionals+=("$1")
		shift
		;;
	esac
done

while [ $# -gt 0 ]; do
	positionals+=("$1")
	shift
done

VERBOSE=$verbose

# _pinfo <text...>
#   Status-level output. Suppressed when silent mode is active.
#   Warnings go through warn(); errors stay on stderr untouched.
_pinfo() {
  [ "${silent:-0}" -eq 1 ] && return 0
  printf '%s\n' "$*"
}

# --- Pre-auth sudo for AIK ------------------------------
# AIK's cleanup.sh needs root to remove the ramdisk dir.
# Prompting for a password *inside* our tee'd region leaves
# the terminal in a broken state (sudo flips it to raw mode
# and the outer pipe stops draining). Cache the sudo ticket
# here, before anything is redirected.
if [ "${tool,,}" = "aik" ]; then
	if ! sudo -v; then
		echo "❌ Error: sudo authentication failed." >&2
		exit 1
	fi
fi

# Install logging only now – after arg parsing, so --help
# and auth errors don't produce empty log sections.
log_init "$(basename -- "$0")" "${orig_args[@]}"

# --- Pipeline progress ----------------------------------
# Only renders when this script was invoked as part of a chain
# (build-it.sh exports KIT_PIPELINE_STATE). Standalone runs are a
# no-op.
powerline_emit pack-it

# --- Resolve positional arguments -----------------------

detect_kind() {
	local f="$1" ft
	[ -f "$f" ] || { echo "missing"; return; }
	ft=$(get_file_type "$f" 2>/dev/null) || { echo "unknown"; return; }
	case "$ft" in
		*Android*bootimg*|*Android*boot*image*) echo "bootimg" ;;
		*Device\ Tree\ Blob*|*device\ tree\ blob*) echo "dtb" ;;
		*) echo "other" ;;
	esac
}

positional_kernel=""
positional_boot=""
n_pos=${#positionals[@]}

if [ "$n_pos" -eq 1 ]; then
	kind=$(detect_kind "${positionals[0]}")
	if [ "$kind" = "bootimg" ]; then
		positional_boot="${positionals[0]}"
	else
		positional_kernel="${positionals[0]}"
	fi
elif [ "$n_pos" -eq 2 ]; then
	k0=$(detect_kind "${positionals[0]}")
	k1=$(detect_kind "${positionals[1]}")
	if [ "$k0" = "bootimg" ] && [ "$k1" != "bootimg" ]; then
		positional_kernel="${positionals[1]}"
		positional_boot="${positionals[0]}"
	else
		positional_kernel="${positionals[0]}"
		positional_boot="${positionals[1]}"
	fi
elif [ "$n_pos" -gt 2 ]; then
	echo "❌ Error: Too many positional arguments." >&2
	exit 1
fi

if [ -n "$positional_kernel" ]; then
	kernel_path="$positional_kernel"
fi

if [ -n "$positional_boot" ]; then
	if [ "$boot_source_set" -eq 1 ]; then
		echo "❌ Error: Boot image specified both via -b/--boot-image and positionally." >&2
		exit 1
	fi
	boot_source="$positional_boot"
fi

boot_name="$(basename -- "${boot_source}")"
boot_target="${KIT_PACK_CFG_AIK_DIR}/${boot_name}"

# --- Resolve kernel image (fallback) --------------------

if [ -z "$kernel_path" ]; then
	kernel_candidates=(
		"zImage-dtb"
		"Image.gz-dtb"
		"zImage"
		"Image.gz"
		"Image"
		"uImage"
	)
	for candidate in "${kernel_candidates[@]}"; do
		if [ -f "${BUILD_DIR}/${candidate}" ]; then
			kernel_path="${BUILD_DIR}/${candidate}"
			break
		fi
	done
	if [ -z "$kernel_path" ]; then
		echo "❌ Error: No kernel image found in ${BUILD_DIR}." >&2
		echo " 👉 Tried: ${kernel_candidates[*]}" >&2
		exit 1
	fi
fi

# --- Device tree handling -------------------------------

kernel_has_appended_dtb() {
	case "$(basename -- "$1")" in
		*dtb) return 0 ;;
		*) return 1 ;;
	esac
}

if kernel_has_appended_dtb "$kernel_path"; then
	if [ -n "$dtb_image" ]; then
		warn "Kernel '${kernel_path}' already contains an appended device tree; ignoring dtb image '${dtb_image}'."
		dtb_image=""
	fi
	remove_old_dtb=1
else
	if [ -z "$dtb_image" ] && [ -f "${BUILD_DIR}/boot-dt.img" ]; then
		dtb_image="${BUILD_DIR}/boot-dt.img"
	fi

	if [ -n "$dtb_image" ]; then
		if [ ! -f "$dtb_image" ]; then
			echo "❌ Error: dtb image not found: ${dtb_image}" >&2
			exit 1
		fi
	else
		warn "Kernel '${kernel_path}' has no appended device tree and no dtb image was provided. The existing device tree from the source boot image will be kept. This may be incompatible with the new kernel."
		remove_old_dtb=0
	fi
fi

# --- Preflight checks -----------------------------------

check_file "${kernel_path}"

if [ -n "$ramdisk_add" ] && [ ! -d "$ramdisk_add" ]; then
	echo "❌ Error: ramdisk overlay directory not found: ${ramdisk_add}" >&2
	exit 1
fi

# --- Dummy 'clear' to silence AIK -----------------------

disable_clear() {
	tmp_bin=$(mktemp -d)
	echo '#!/bin/sh' >"$tmp_bin/clear"
	chmod +x "$tmp_bin/clear"
	export PATH="$tmp_bin:$PATH"
	trap 'rm -rf "$tmp_bin"' EXIT
}

# --- Cleanup --------------------------------------------

aik_cleanup() {
	if [ -d "${KIT_PACK_CFG_AIK_DIR}/split_img" ]; then
		_pinfo "🧹 Performing AIK cleanup"
		run_tool "${KIT_PACK_CFG_AIK_DIR}/cleanup.sh"
	fi
}

magisk_cleanup() {
	if [ -d "${MAGISK_WORK_DIR}" ]; then
		_pinfo "🧹 Performing Magisk cleanup"
		rm -rf "${MAGISK_WORK_DIR}"
	fi
}

# --- Unpack ---------------------------------------------

aik_unpack() {
	_pinfo "📤 Using AIK to unpack boot image (${1})"
	run_tool "${KIT_PACK_CFG_AIK_DIR}/unpackimg.sh" "${1}"
}

magisk_unpack() {
	local src
	src="$(readlink -f -- "$1")"
	_pinfo "📤 Using magiskboot to unpack boot image (${src})"
	mkdir -p "${MAGISK_WORK_DIR}"
	( cd "${MAGISK_WORK_DIR}" && run_tool magiskboot unpack "${src}" )
}

# --- Repack ---------------------------------------------

aik_repack() {
	_pinfo "🔧 Using AIK to repack a new boot image"
	run_tool "${KIT_PACK_CFG_AIK_DIR}/repackimg.sh"
}

magisk_repack() {
	local src out
	src="$(readlink -f -- "$1")"
	out="$2"
	_pinfo "🔧 Using magiskboot to repack a new boot image"
	( cd "${MAGISK_WORK_DIR}" && run_tool magiskboot repack "${src}" "${out}" )
}

# --- Replace kernel -------------------------------------

replace_kernel() {
	case "$tool" in
	aik)
		cp "${kernel_path}" "${boot_target}-kernel"
		_pinfo "Replaced ${boot_target}-kernel with new kernel (${kernel_path})"
		;;
	magisk)
		cp "${kernel_path}" "${MAGISK_WORK_DIR}/kernel"
		_pinfo "Replaced ${MAGISK_WORK_DIR}/kernel with new kernel (${kernel_path})"
		;;
	esac
}

# --- Apply device tree ----------------------------------

apply_dtb() {
	local dt_target
	case "$tool" in
	aik)    dt_target="${boot_target}-dt" ;;
	magisk) dt_target="${MAGISK_WORK_DIR}/dtb" ;;
	*)      return 0 ;;
	esac

	if [ -n "$dtb_image" ]; then
		cp "$dtb_image" "$dt_target"
		_pinfo "🌲 Applied dtb image: ${dtb_image}"
	elif [ "$remove_old_dtb" -eq 1 ]; then
		_pinfo "🗑️  Deleting old device tree file (${dt_target})"
		rm -f "${dt_target}"
	fi
}

# --- Ramdisk overlay ------------------------------------

ramdisk_has_work() {
	[ -n "$ramdisk_add" ] || [ ${#ramdisk_rm[@]} -gt 0 ]
}

ramdisk_check_overlay() {
	local src
	while IFS= read -r -d '' src; do
		if [ -L "$src" ]; then
			echo "❌ Error: symlinks not supported in ramdisk overlay: ${src}" >&2
			exit 1
		fi
		if [ ! -f "$src" ]; then
			echo "❌ Error: only regular files supported in ramdisk overlay: ${src}" >&2
			exit 1
		fi
	done < <(find "$ramdisk_add" ! -type d -print0)
}

ramdisk_apply() {
	ramdisk_has_work || return 0
	case "$tool" in
	aik)    ramdisk_apply_aik ;;
	magisk) ramdisk_apply_magisk ;;
	esac
}

ramdisk_apply_aik() {
	local ramdisk_dir="${KIT_PACK_CFG_AIK_DIR}/ramdisk"
	[ -d "$ramdisk_dir" ] || {
		echo "❌ Error: AIK ramdisk dir not found: ${ramdisk_dir}" >&2
		exit 1
	}

	local entry src dest

	for entry in "${ramdisk_rm[@]:-}"; do
		[ -z "$entry" ] && continue
		dest="${ramdisk_dir}/${entry#/}"
		if [ -e "$dest" ] || [ -L "$dest" ]; then
			rm -rf -- "$dest"
			_pinfo "🗑️  Removed from ramdisk: ${entry}"
		else
			warn "ramdisk-rm: entry not found: ${entry}"
		fi
	done

	[ -z "$ramdisk_add" ] && return 0
	ramdisk_check_overlay

	while IFS= read -r -d '' src; do
		entry="${src#"${ramdisk_add}"/}"
		dest="${ramdisk_dir}/${entry}"
		if [ ! -e "$dest" ] && [ "$ramdisk_strict" -eq 1 ]; then
			warn "ramdisk-strict: new entry not present in original ramdisk: ${entry}"
		fi
		mkdir -p -- "$(dirname -- "$dest")"
		cp -a -- "$src" "$dest"
		_pinfo "  ↳ ${entry}"
	done < <(find "$ramdisk_add" -type f -print0)

	_pinfo "📁 Applied ramdisk overlay (AIK): ${ramdisk_add}"
}

ramdisk_apply_magisk() {
	local cpio="${MAGISK_WORK_DIR}/ramdisk.cpio"
	[ -f "$cpio" ] || {
		echo "❌ Error: ramdisk.cpio not found in ${MAGISK_WORK_DIR}" >&2
		exit 1
	}

	local entry src mode

	for entry in "${ramdisk_rm[@]:-}"; do
		[ -z "$entry" ] && continue
		entry="${entry#/}"
		if ( cd "${MAGISK_WORK_DIR}" && magiskboot cpio ramdisk.cpio "exists ${entry}" ) >/dev/null 2>&1; then
			( cd "${MAGISK_WORK_DIR}" && magiskboot cpio ramdisk.cpio "rm ${entry}" ) >/dev/null
			_pinfo "🗑️  Removed from ramdisk: ${entry}"
		else
			warn "ramdisk-rm: entry not found: ${entry}"
		fi
	done

	[ -z "$ramdisk_add" ] && return 0
	ramdisk_check_overlay

	while IFS= read -r -d '' src; do
		entry="${src#"${ramdisk_add}"/}"
		entry="${entry#/}"
		mode=$(stat -c '%a' "$src")

		if ! ( cd "${MAGISK_WORK_DIR}" && magiskboot cpio ramdisk.cpio "exists ${entry}" ) >/dev/null 2>&1; then
			if [ "$ramdisk_strict" -eq 1 ]; then
				warn "ramdisk-strict: new entry not present in original ramdisk: ${entry}"
			fi
		fi

		( cd "${MAGISK_WORK_DIR}" && magiskboot cpio ramdisk.cpio "add ${mode} ${entry} ${src}" ) >/dev/null
		_pinfo "  ↳ ${entry} (mode ${mode})"
	done < <(find "$ramdisk_add" -type f -print0)

	_pinfo "📁 Applied ramdisk overlay (magisk): ${ramdisk_add}"
}

# --- Run ------------------------------------------------

tool=${tool,,}
case "$tool" in
aik)
	disable_clear
	aik_cleanup
	aik_unpack "${boot_source}"
	;;
magisk)
	magisk_cleanup
	magisk_unpack "${boot_source}"
	;;
*)
	echo "Repack tool ${tool} is not supported." >&2
	exit 1
	;;
esac

replace_kernel "${kernel_path}"
apply_dtb
ramdisk_apply

case "$tool" in
aik)    aik_repack ;;
magisk) magisk_repack "${boot_source}" "${MAGISK_WORK_DIR}/new-boot.img" ;;
esac

# --- Output ---------------------------------------------

case "$tool" in
aik)    new_image="${KIT_PACK_CFG_AIK_DIR}/image-new.img" ;;
magisk) new_image="${MAGISK_WORK_DIR}/new-boot.img" ;;
esac

if [ ! -f "${new_image}" ]; then
	echo "❌ Error: ${tool} did not produce ${new_image}." >&2
	exit 1
fi

final_image="${new_image}"
if [ -n "$output" ]; then
	if [ -d "$output" ] || [ "${output%/}" != "$output" ]; then
		mkdir -p "$output"
		dest="${output%/}/boot.img"
	else
		dest="$output"
		mkdir -p "$(dirname -- "$dest")"
	fi
	mv "${new_image}" "${dest}"
	final_image="${dest}"
fi

_pinfo "🎁 Created new boot image: ${final_image}"

# --- Flash, if requested --------------------------------

if [ "${flash}" -eq 1 ]; then
  if [ -z "${KIT_DIR:-}" ]; then
    echo "❌ Error: KIT_DIR is not set; cannot locate flash-it.sh." >&2
    exit 1
  fi
	_pinfo "⚡ Flashing ${final_image} ..."
  powerline_emit flash-it
  flash_args=("${final_image}")
  [ "${verbose}" -eq 1 ] && flash_args=(--verbose "${final_image}")
	[ "${silent}"  -eq 1 ] && flash_args+=(--silent)
  if ! "${KIT_DIR}/flash-it.sh" "${flash_args[@]}"; then
    echo "❌ Error: flash-it.sh failed." >&2
    exit 1
  fi
fi