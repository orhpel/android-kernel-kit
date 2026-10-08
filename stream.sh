#!/usr/bin/env bash
# ========================================================
# Android Kernel Kit
#
# --- stream.sh ---
## stream.sh (lib)

# Live-streaming UI for long-running commands. Requires tmux.
# Falls back to `run_tool` when tmux is unavailable or not in a session.

# ### Detection
# - `stream_available` → 0 if tmux present and inside a tmux session
#
# ### Auto-launch
# - `stream_ensure_tmux <script> [args...]`
#   Called early from executables; re-launches the script inside a
#   fresh tmux session (unless KIT_COMMON_OPT_NO_TMUX=1 or already in tmux or
#   no TTY). Inner script runs via a temp wrapper under `/tmp`,
#   which writes the inner exit code to a sidecar file because
#   tmux itself always reports 0 on a clean detach.
#   On non-zero inner exit, prints error context (grep -C 15 "error:")
#   in the *outer* shell, since tmux's alt-screen discards the
#   session output on exit.
#
# ### Pane control
# - `stream_pane_open <stream_log> <title>` → open tailing pane; returns pane id
# - `stream_pane_close <pane_id>`
#
# ### High-level
# - `ui_stream <title> <cmd...>`   → run command, stream to pane + session log
#                                     honors $STREAM_EXTRA_LOG for per-call tee
#                                     on failure: writes error context to pane,
#                                     waits for Enter, returns cmd exit code
# - `stream_write <text...>`       → append to active pane log
#
# ### Traps
# - Preserves and restores caller traps around the stream
#   (essential: log_init installs an EXIT/INT/TERM/HUP trap)
# - On Ctrl-C during a stream: cleans up pane + temp log, session ends
# ========================================================

if [ "${_STREAM_SH_LOADED:-0}" -eq 1 ]; then
  return 0
fi
_STREAM_SH_LOADED=1

# --- Dependencies ---------------------------------------

if ! declare -F run_tool >/dev/null 2>&1 || ! declare -F log_path >/dev/null 2>&1; then
  echo "❌ stream.sh: 'run_tool' and 'log_path' not defined. Source common.sh before stream.sh." >&2
  return 1
fi

# --- Appearance -----------------------------------------

: "${KIT_STREAM_CFG_SPLIT_MIN_WIDTH:=100}"
: "${KIT_STREAM_CFG_SPLIT_SIZE:=40%}"
: "${KIT_STREAM_CFG_USE_STDBUF:=1}"

# --- State ----------------------------------------------

declare -g _STREAM_PANE=""
declare -g _STREAM_STREAM_LOG=""
declare -g _STREAM_INTERRUPTED=0

# --- Detection ------------------------------------------

# stream_available
#   Returns 0 if tmux is installed and the current shell is
#   inside a tmux session.
stream_available() {
  command -v tmux >/dev/null 2>&1 && [ -n "${TMUX:-}" ]
}

# --- Cleanup --------------------------------------------

_stream_cleanup() {
  if [ -n "${_STREAM_PANE:-}" ]; then
    tmux kill-pane -t "$_STREAM_PANE" 2>/dev/null || true
    _STREAM_PANE=""
  fi
  if [ -n "${_STREAM_STREAM_LOG:-}" ]; then
    rm -f -- "$_STREAM_STREAM_LOG"
    _STREAM_STREAM_LOG=""
  fi
}

_stream_on_signal() {
  _STREAM_INTERRUPTED=1
  _stream_cleanup
}

# --- Pane control ---------------------------------------

# stream_ensure_tmux <script-path> [args...]
#
#   If not already inside a tmux session and tmux is available, re-executes
#   <script-path> with [args...] inside a new tmux session. The session name
#   is derived from the current shell PID so concurrent runs don't collide.
#
#   Launches tmux and attaches to it, blocking until the session ends.
#   The inner script's exit code is captured in a temp file (tmux always
#   reports 0 on clean detach), and the outer script exits with that code.
#
#   Returns 1 if no re-exec was needed or possible:
#     - already inside tmux ($TMUX is set), or
#     - tmux is not installed, or
#     - stdin or stdout is not a tty (piped / scripted context), or
#     - KIT_COMMON_OPT_NO_TMUX=1 is set.
#
#   Env:
#     KIT_COMMON_OPT_NO_TMUX          Set to 1 to skip the auto-launch.
#     KIT_STREAM_CFG_TMUX_SESSION  Override the session name (default: kit-build-<pid>).
stream_ensure_tmux() {
  [ "${KIT_COMMON_OPT_NO_TMUX:-0}" = "1" ] && return 1
  [ -n "${TMUX:-}" ] && return 1
  command -v tmux >/dev/null 2>&1 || return 1
  [ -t 0 ] && [ -t 1 ] || return 1

  local script="${1:?stream_ensure_tmux: script path required}"; shift
  local abs_script
  if [[ "$script" == */* ]]; then
    abs_script=$(readlink -f -- "$script" 2>/dev/null) || abs_script="$script"
  else
    abs_script=$(command -v -- "$script" 2>/dev/null) || abs_script="$script"
    abs_script=$(readlink -f -- "$abs_script" 2>/dev/null) || true
  fi

  local session="${KIT_STREAM_CFG_TMUX_SESSION:-kit-build-$$}"
  local exitcode_file="${TMPDIR:-/tmp}/kit-tmux-$$.exit"
  rm -f -- "$exitcode_file"

	# Dedicated tmux server for this session, on its own socket.
  # Rationale:
  #   - A fresh server reads the -f config on startup (an already
  #     running server ignores -f entirely).
  #   - Window options such as alternate-screen are applied when the
  #     window is created, so they must be in place before new-session.
  #   - The user's own tmux server and sessions are not touched.
  local socket="${TMPDIR:-/tmp}/kit-tmux-$$.socket"
  local tmuxrc="${XDG_RUNTIME_DIR:-/tmp}/kit-tmux.conf"
  {
    if [ -f "$HOME/.tmux.conf" ]; then
      printf 'source-file %q\n' "$HOME/.tmux.conf"
    fi
    printf 'set -g mouse on\n'
  } > "$tmuxrc" || return 1

  # Build a tiny wrapper script that runs the target under bash and
  # captures its exit code. At the end it detaches the client so the
  # outer shell can capture the pane contents before the server dies.
  local wrapper="${TMPDIR:-/tmp}/kit-tmux-$$-wrapper.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'cd %q || exit 1\n' "$PWD"
    printf '%q ' "$abs_script" "$@"
    printf '\nec=$?\n'
    # shellcheck disable=SC2016 # $ec is meant to be literal in the wrapper
    printf 'printf "%%s" "$ec" > %q\n' "$exitcode_file"
    printf 'tmux -S %q detach-client -s %q 2>/dev/null || true\n' "$socket" "$session"
  } > "$wrapper" || return 1
  chmod +x "$wrapper"

  # Dedicated tmux server for this session, on its own socket.
  # Rationale:
  #   - A fresh server reads the -f config on startup (an already
  #     running server ignores -f entirely).
  #   - Window options such as alternate-screen are applied when the
  #     window is created, so they must be in place before new-session.
  #   - The user's own tmux server and sessions are not touched.
    local tmuxrc="${XDG_RUNTIME_DIR:-/tmp}/kit-tmux.conf"
  {
    if [ -f "$HOME/.tmux.conf" ]; then
      printf 'source-file %q\n' "$HOME/.tmux.conf"
    fi
		printf 'set -g mouse on\n'
    # Keep the pane around after its process exits, so the outer
    # shell has time to capture-pane before the server shuts down.
    printf 'set -g remain-on-exit on\n'
    # Blank the "Pane is dead" banner; we only want the actual output.
    printf 'set -g remain-on-exit-format ""\n'
  } > "$tmuxrc" || return 1

	tmux -S "$socket" -f "$tmuxrc" new-session -d -s "$session" "bash $wrapper"
  tmux -S "$socket" attach -t "$session" 2>/dev/null

  # The wrapper detached us before exiting, so the session is still
  # alive here. Capture the pane's full scrollback before tearing
  # down the server — this is what the user saw during the session.
  #   -p        : print to stdout
  #   -J        : join wrapped lines (avoid hard line breaks)
  #   -S -      : start from the very beginning of the scrollback
	local captured
  captured=$(tmux -S "$socket" capture-pane -p -e -J -S - -t "$session" 2>/dev/null \
             | awk '{l[NR]=$0; tmp=$0; gsub(/\033\[[0-9;]*m/, "", tmp); if(length(tmp)>0) n=NR} END{for(i=1;i<=n;i++) print l[i]}' || true)

  tmux -S "$socket" kill-server 2>/dev/null || true
  rm -f -- "$socket"

  rm -f -- "$wrapper"

  local rc
  if [ -f "$exitcode_file" ]; then
    rc=$(<"$exitcode_file")
    rm -f -- "$exitcode_file"
  else
    rc=1
    printf '⚠️  tmux session exited without reporting a status; treating as failure.\n' >&2
  fi

	# Print the captured pane content. This is the session output the
  # user watched inside tmux, now replayed in the outer shell.
  if [ -n "$captured" ]; then
    printf '\n' >&2
    printf '%s\n' "$captured" >&2
  fi

  # Point at the log file for anyone who wants the raw session record.
  local log_dir
  if [ -n "${KIT_COMMON_CFG_LOG_DIR:-}" ]; then
    log_dir="$KIT_COMMON_CFG_LOG_DIR"
  else
    local proj_root
    proj_root=$(find_project_folder 2>/dev/null || true)
    log_dir="${proj_root:-$PWD}/logs"
  fi
  local latest_log="" f
  for f in "$log_dir"/run-*.log; do
    [ -f "$f" ] || continue
    latest_log="$f"
  done
  if [ -n "$latest_log" ]; then
    printf '\n📋 Session log: %s\n' "$(readlink -f -- "$latest_log")" >&2
  fi

  exit "$rc"
}


# stream_pane_open <stream_log> <title>
#   Opens a tmux pane that follows <stream_log>.
#   Prints the pane id on success, returns non-zero on failure.
stream_pane_open() {
  local stream_log="$1" title="$2"
  local width direction before=""
  width=$(tmux display-message -p '#{window_width}' 2>/dev/null || echo 120)
  if [ "$width" -ge "$KIT_STREAM_CFG_SPLIT_MIN_WIDTH" ]; then
    direction="-h"
  else
    direction="-v"
    before="-b"   # vertical: put the new pane above the main one
  fi

  printf -v cmd 'tail -n +1 -f %q' "$stream_log"

  tmux split-window "$direction" $before -l "$KIT_STREAM_CFG_SPLIT_SIZE" -d \
    -P -F '#{pane_id}' "$cmd"
}

# stream_pane_close <pane_id>
stream_pane_close() {
  local pane_id="${1:-}"
  [ -z "$pane_id" ] && return 0
  tmux kill-pane -t "$pane_id" 2>/dev/null || true
}

# --- High-level API -------------------------------------

# stream_write <text...>
#   Appends text to the currently active stream pane's log, if any.
#   Useful for callers that want to surface error analysis inside the
#   streaming pane before it closes.
stream_write() {
  [ -n "${_STREAM_STREAM_LOG:-}" ] || return 0
  [ -f "$_STREAM_STREAM_LOG" ] || return 0
  printf '%s\n' "$*" >> "$_STREAM_STREAM_LOG"
}

# ui_stream <title> <command...>
#   Runs <command> and streams its output to a tmux pane and to
#   the active kit log. Falls back to run_tool() when tmux is
#   unavailable.
#
#   Returns the exit code of <command>.
ui_stream() {
	
  local title="${1:-}"
  if [ -z "$title" ]; then
    echo "❌ ui_stream: title required." >&2
    return 1
  fi
  shift

  if [ "$#" -eq 0 ]; then
    echo "❌ ui_stream: command required." >&2
    return 1
  fi

  # --- Fallback: no tmux, no session -------------------
  if ! stream_available; then
    run_tool "$@"
    return $?
  fi

	# --- Preserve caller traps ---------------------------
  # ui_stream temporarily overrides INT/TERM/HUP to clean up its pane
  # on Ctrl-C. Bash traps are shell-scoped, so we must save and restore
  # any traps the caller (e.g. log_init) installed.
  local _saved_traps
  _saved_traps=$(trap -p)

  _STREAM_INTERRUPTED=0
  trap '_stream_on_signal' INT TERM HUP

  local session_log
  session_log=$(log_path)

  # --- Dedicated stream log for the pane ---------------
  _STREAM_STREAM_LOG=$(mktemp "${TMPDIR:-/tmp}/kit-stream.XXXXXX") || {
    run_tool "$@"
    return $?
  }

  {
    printf '%s\n' "🔨 $title"
    printf '\n'
  } > "$_STREAM_STREAM_LOG"

  # --- Header for the session log ----------------------
  if [ -n "$session_log" ]; then
    {
      printf '\n'
      printf '===== %s | %s =====\n' "$title" "$(date '+%Y-%m-%d %H:%M:%S')"
      printf 'cmd:'
      printf ' %q' "$@"
      printf '\n\n'
    } >> "$session_log"
  fi

  # --- Open pane ---------------------------------------
  _STREAM_PANE=$(stream_pane_open "$_STREAM_STREAM_LOG" "$title") || {
    echo "⚠️  ui_stream: could not open tmux pane; falling back to run_tool." >&2
    _stream_cleanup
    local fallback_rc
    run_tool "$@"
    fallback_rc=$?
    return "$fallback_rc"
  }

  # --- Install signal trap -----------------------------
  _STREAM_INTERRUPTED=0
  trap '_stream_on_signal' INT TERM HUP

  # --- Run the command ---------------------------------
  # stdbuf forces line buffering so make's own output streams
  # live instead of arriving in 4 KB chunks. Best effort: if the
  # command ignores it (static binary, script), it just behaves
  # as before.
  local -a runner=()
  if [ "$KIT_STREAM_CFG_USE_STDBUF" -eq 1 ] && command -v stdbuf >/dev/null 2>&1; then
    runner=(stdbuf -oL -eL)
  fi

  local rc=0
  local -a tee_args=(-a "$_STREAM_STREAM_LOG")
  [ -n "${STREAM_EXTRA_LOG:-}" ] && tee_args+=("$STREAM_EXTRA_LOG")

  if [ -n "$session_log" ]; then
    "${runner[@]}" "$@" 2>&1 | tee "${tee_args[@]}" >> "$session_log"
    rc=${PIPESTATUS[0]}
  else
    "${runner[@]}" "$@" 2>&1 | tee "${tee_args[@]}" >/dev/null
    rc=${PIPESTATUS[0]}
  fi

  # Give the pane a moment to render the final lines before it
  # closes (or before we prompt for a key).
  sleep 0.3

	# --- On failure: surface error context in the pane ---
  if [ "$rc" -ne 0 ] && [ "$_STREAM_INTERRUPTED" -eq 0 ]; then
    local context="${KIT_STREAM_CFG_ERROR_CONTEXT:-15}"
    if [ "$context" -gt 0 ] && [ -f "$_STREAM_STREAM_LOG" ]; then
      local err_out
      err_out=$(grep -i -C "$context" "error:" "$_STREAM_STREAM_LOG" \
        | tail -n 200) || true
      if [ -z "$err_out" ]; then
        err_out=$(tail -n 40 "$_STREAM_STREAM_LOG")
      fi
      if [ -n "$err_out" ]; then
        {
          printf '\n'
          printf '════════════════════════════════════════\n'
          printf '❌ Error context\n'
          printf '════════════════════════════════════════\n'
          printf '%s\n' "$err_out"
          printf '════════════════════════════════════════\n'
        } >> "$_STREAM_STREAM_LOG"
      fi
    fi

    # Let tail -f in the pane actually render the new lines.
    sleep 1

    printf '\n❌ Command failed (exit %d). Press Enter to close the pane... ' "$rc" >&2
    read -rsr </dev/tty 2>/dev/null || true
    printf '\n' >&2
  fi

	# Give the pane a moment to render the final lines before closing.
  sleep 0.5

	# --- Cleanup -----------------------------------------
  _stream_cleanup
  eval "${_saved_traps:-:}"

  return "$rc"
}