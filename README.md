# Android Kernel Kit

> The missing toolkit between `make zImage` and _"it booted!"_

**AKK** is a bash toolkit for the Android kernel dev workflow.
It takes you from a fresh source tree to a flashed, verified, and
debuggable build — without a jungle of shell history.

Here's the whole flow, in one line:

~~~
   clean  →  build  →  pack  →  flash  →  logs / debug
    🧹        🔨       📦      ⚡         🩺
~~~

Or as a one-shot:

~~~bash
build-it.sh -r -f              # build + repack + flash, in one go
~~~

How it differs from the classic flow: traditionally you'd build the
kernel, sign it, and assemble a fresh boot.img from scratch. AKK skips
all that -- it takes an existing boot.img, swaps in the freshly built
kernel, and repacks. No signing keys, no AVB work, no rebuilding what
you already trust. Just a swap and a flash.

Built for one thing and one thing only: getting your kernel onto your
device, reliably, repeatedly, and with enough logs to figure out what
went wrong when it doesn't.

---

## What's inside

| Script | What it does |
|---|---|
| `config-it.sh`   | Interactive config editor + guided tool setup |
| `clean-it.sh`    | `make clean && make mrproper`, with `.config` rescue |
| `build-it.sh`    | Build the kernel, archive the result, optional repack |
| `pack-it.sh`     | Repack boot.img via AIK or magiskboot |
| `flash-it.sh`    | Push + flash over adb, with sanity checks |
| `log-it.sh`      | Pull kernel and system logs from the device |
| `debug-it.sh`    | Full debug bundle (getprop, tombstones, build.prop, +30 more) |
| `toolchain.sh`   | Pick a toolchain per project |
| `magictest.sh`   | Magic-byte validator (used internally by other scripts) |

Libraries (`common.sh`, `menu.sh`, `stream.sh`, `config-schema.sh`)
are sourced, never executed.

## Notable features

- **Automatic DTB handling.** `build-it` builds `zImage dtbs` by default,
  invokes `dtbTool` automatically when the target kernel has no appended
  device tree, and hands the resulting `boot-dt.img` to `pack-it` at
  repack time. No missing pieces, no manual steps.
- **Live build output** in a tmux pane — errors get replayed in the outer
  shell after the session ends, because tmux's alt-screen would otherwise
  eat them.
- **One config file per scope.** Config lives in `.kit` files — one for
  the kit, one per project. Not scattered across six hidden dot-files.
- **Toolchains, configured once.** Set up a toolchain globally, and every
  project picks it up. Or override per project when you need a different
  one. Switch anytime with `toolchain.sh` — name on the CLI, or an
  interactive menu if you prefer. Toolchain configs are plain shell
  scripts that get sourced, so anything from a simple `CROSS_COMPILE`
  prefix to a full custom environment is a one-liner away.
- **Schema-driven.** Every option is declared once. Delta pruning keeps
  project files minimal: overrides that match the inherited value get
  removed automatically.
- **Guided setup.** `config-it` detects missing tools and offers to
  install them (AIK, dtbTool, toolchain). Nothing happens without your
  say-so.
- **NerdFont progress line** for people who like their terminal pretty.
- **Full --help on every script.** Every script ships with a complete
  usage text -- usage, description, arguments, options, examples, and
  exit codes. No guessing, no reading the source. Just run any script
  with -h or --help and it tells you exactly what it does.
- **Pure bash.** No Python, no build server, no "install our CLI" ritual.

## The philosophy

The kit **guides, it doesn't force**. Missing a tool? It offers to
install it. Broken config? It tells you which line. You want to run
everything by hand? Be our guest — every script works standalone.

## Requirements

| Tool | Why | Required |
|---|---|---|
| `bash` >= 5.x | Everything | ✅ |
| `gum` >= 0.14.0 | Menus | ✅ for `config-it`, `toolchain.sh`, build progress UI |
| `file` >= 5.40 | Magic-byte detection | ✅ |
| `adb` | Flashing, logs, debug bundle | ✅ for device-side scripts |
| `make`, `nproc` | Kernel build | ✅ for `build-it` |
| `tmux` | Live build streaming | ⚪ optional (falls back to plain output) |
| `tqdm` or `pv` | Progress bar outside tmux | ⚪ optional |
| Android Image Kitchen | Boot image repack (aik mode) | ⚪ optional |
| magiskboot | Boot image repack (magisk mode) | ⚪ optional |
| LineageOS dtbTool | DTB append for non-DTB kernels | ⚪ only if you need `boot-dt.img` |
| A NerdFont | Powerline progress line + decorative glyphs | ⚪ optional |

**Note on `magiskboot`:** `pack-it` needs *either* AIK or `magiskboot` —
not both. AIK is the default and offers a guided install via `config-it.sh`.
`magiskboot` must be available in `PATH`. The official Linux binaries from
Magisk releases have known issues on some distributions (e.g. Ubuntu 22.04).
A working x86_64 build is available in
[`affggh/Magisk_patcher@a101f7b`](https://github.com/affggh/Magisk_patcher/blob/a101f7b3f2e2989da2ab7def2add00b0a873e8d0/bin/linux/x86_64/magiskboot)
— download the binary from that commit and put it in your `PATH`.

*The linked commit provides a recompiled x86_64 binary that works on
cachyos 7.2.9, Ubuntu 22.04 and similar; the official `magiskboot` from Magisk releases
does not run on all Linux setups.*

## Quickstart

~~~bash
# Clone the kit somewhere sensible
git clone https://github.com/<you>/android-kernel-kit ~/Projects/android-kernel-kit

# Make the scripts callable (optional but recommended)
export PATH="$HOME/Projects/android-kernel-kit:$PATH"

# First-time config — kit-wide defaults
cd ~/Projects/android-kernel-kit
./config-it.sh -g

# Project config — per-tree tweaks
cd ~/Projects/kernel_foo
config-it.sh
~~~

The config menu detects missing tools (AIK, dtbTool, toolchain) and
offers to install them. Nothing happens without your say-so.

## Usage

### Build

~~~bash
build-it.sh                    # default: zImage + dtbs (recommended)
build-it.sh -l mytest          # append to LOCALVERSION
build-it.sh -c                 # clean first
build-it.sh -N zImage          # no tmux, plain output
~~~

By default, `build-it` builds `zImage dtbs` — the kernel image **and**
the device tree blobs. When the target kernel doesn't have an appended
DTB, the kit invokes `dtbTool` automatically, produces `boot-dt.img`,
and hands it over to `pack-it` later. One command, no missing pieces.

Live build output runs in a tmux pane (if tmux is available). Errors
get replayed in the outer shell after the session ends — because tmux's
alt-screen would otherwise eat them.

### Pack

~~~bash
pack-it.sh                     # finds the newest kernel in BUILD_DIR
pack-it.sh -b boot.img         # repack against a specific source image
pack-it.sh -t boot-dt.img      # inject a device tree
pack-it.sh -r ./overlay        # overlay files (like a new fstab) into the ramdisk
~~~

### Flash

~~~bash
flash-it.sh boot.img           # push, flash, reboot
flash-it.sh -k boot.img        # keep the image on device
flash-it.sh -rs boot.img       # silent, no reboot
flash-it.sh -t /sdcard/boot.img # already-on-device path
~~~

Magic-byte check before writing to a boot partition. You're welcome.

### Logs & debug

~~~bash
log-it.sh                      # dmesg, kmsg, ramoops, logcat
debug-it.sh                    # getprop, tombstones, build.prop, +30 more
~~~

`debug-it.sh` produces a timestamped folder you can zip and throw at
whoever asked for "logs". They'll be delighted. Or at least, less annoyed.

## Configuration

All config lives in `.kit` files:

~~~
$KIT_DIR/.kit              global defaults
$PROJECT_ROOT/.kit         project overrides
~~~

Precedence (low → high): schema default → global `.kit` → project
`.kit` → environment. Overrides that match the inherited value are
automatically pruned, so project files stay minimal.

*For kernel trees that don't have both Makefile and AndroidKernel.mk in the root (AOSP-style trees, for instance), drop an empty .project file in the project root so the kit can find it. LineageOS-style trees are detected automatically.*

Edit with the menu:

~~~bash
config-it.sh                   # project config (auto-detected)
config-it.sh -g                # global config
config-it.sh -l                # plain-text list
~~~

Or by hand — the format is boring on purpose:

~~~bash
# Comment
KIT_FLASH_CFG_BOOT_DEVICE="/dev/block/mmcblk0p20"
KIT_BUILD_CFG_AUTO_ARCHIVE="1"
~~~

## Why another kernel toolkit?

Because the existing options are either:

- **Full IDEs** that want to own your workflow (and your disk)
- **One-off scripts** that solve one problem and then rot
- **Wrapper frameworks** that only work if you use *their* toolchain

AKK is deliberately none of those. It's a set of small, focused scripts
that:

- Work on any Android kernel tree (LineageOS-style, AOSP, vendor)
- Survive you switching devices, ROMs, and toolchains
- Fall back gracefully when optional tools are missing
- Stay readable enough to hack on when you want to add something

## Status

**Release candidate.** The core workflow (build → repack → flash → log)
is tested and stable. Actively developed against LineageOS 17.1 on
a Samsung T560/T561; other devices and kernels are untested but should work
with the right configuration.

Rough edges may still exist. Bug reports and PRs welcome — especially
from people running the kit on hardware that isn't a Samsung T560/T561.

## Contributing

Issues and PRs welcome. Before you send a patch:

- Run `shellcheck` over your changes
- Match the style of the surrounding code
- Keep scripts focused — small and single-purpose

## Acknowledgements

The kit was built in a back-and-forth between a human dev and LLM
assistants. The human brought the kernel domain knowledge, the workflow
design, and hours of testing on real hardware; the AI contributed the
bash idioms, the documentation, and an unreasonable tolerance for
`shellcheck` warnings.

The result is entirely the human's kit — but the process was a genuine
collaboration. If you're curious about the workflow:

- [Claude](https://claude.ai/) — by Anthropic
- [DeepSeek](https://deepseek.com/) — the other half of the pair

Pick whichever fits your stack. The kit doesn't care, and neither do we.

## License

MIT — use it, fork it, ship it. If you find it useful, a link back is
appreciated (but the only thing MIT actually requires is keeping the
`LICENSE` file intact when you redistribute).

## Hall of shame

Named after a long tradition of `make` invocations that "should work
this time". If it doesn't boot, it's not the kit's fault. Probably.
Maybe. Open an issue and we'll figure it out together.

---

**AKK** — because your kernel deserves better than a screen session
and a prayer.
