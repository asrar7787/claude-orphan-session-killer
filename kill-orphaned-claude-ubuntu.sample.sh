#!/bin/bash

# Author: Asrar Alam
# License: MIT
#
# claude-orphan-session-killer  (Linux port — Ubuntu 24.04 / GNU coreutils)
#
# Ported from the macOS/launchd template. Changes from the original:
#   * epoch_of() uses GNU `date -d` instead of BSD `date -j -f` (macOS-only flag,
#     unsupported by GNU coreutils — the original would have silently failed the
#     start-epoch match on every PID and pruned every registry entry without
#     ever reaping anything).
#   * Identity guard matches the process by `comm` == "claude" instead of a
#     macOS app-bundle path (`/claude.app/Contents/MacOS/claude`), which does
#     not exist here — sessions run from a plain binary/symlink
#     (~/.local/bin/claude), and `comm` is stable across versions even though
#     the resolved binary path is version-numbered.
#   * Removed the `disclaimer` wrapper-kill and Pass 2 (weekly-usage-limit
#     casualty reaper): both are Claude *Desktop* app concepts (a Helpers
#     wrapper process and ~/Library/Logs/Claude/main.log) that don't exist in
#     this deployment. Here, headless sessions are spawned directly via
#     Node's child_process.spawn (see slack-claude-bot/src/investigation.js),
#     with no wrapper process and no desktop log to correlate against.
#
# Purpose: Reap completed or hung headless Claude Code sessions that belong to
# self-registering scheduled tasks, while never touching anything else.
#
# Safety model:
#   * Only PIDs found in a schedule's own registry are ever candidates.
#     Interactive sessions never register -> are never killed.
#   * Identity guards (fail any one -> skip and prune the entry, NEVER kill):
#       - it is still alive
#       - its `comm` is the claude binary
#       - its live start-time matches the registered start-time (PID-recycle guard)
#   * A PID that passes the guards is reaped by whichever comes first:
#       - early reap: it left a matching pid+start-epoch row in completed.tsv (see
#         below) -> reap now, skipping the MAX_RUN budget.
#       - budget reap: age > that task's MAX_RUN budget. The budget is the boundary:
#         a healthy live run finishes within it, so anything older is done or hung.
#     Otherwise the session is left running.
#
# Files (per scheduled task, under ~/.claude/scheduled-tasks/*/orphan-killer/):
#   * registry.tsv  — live roster, one row per running session.
#       line format:  <pid>\t<start-epoch>\t<task-name>
#   * completed.tsv — early-reap signal. A run appends its own pid+start-epoch
#     row here as its LAST act, once it has finished all work (e.g. an empty
#     "no new messages" poll). A registered PID with a matching row here is
#     reaped on the next pass, regardless of MAX_RUN.
#       line format:  <pid>\t<start-epoch>\t<task-name>\t<utc-iso>\t<message>
#
# Two files on purpose: the reaper rewrites registry.tsv to a strict 3 columns,
# which would strip completed.tsv's extra columns and break the budget lookup.
#
# Env: DRY_RUN=1  -> log intended kills without killing.

DRY_RUN="${DRY_RUN:-0}"
DEFAULT_MAX=1800               # fallback budget (s) for an unknown task
CLAUDE_COMM="claude"           # `ps -o comm=` for a live headless session on this host

LOGDIR="$HOME/.claude/orphan-killer"
LOG="$LOGDIR/killer.log"
mkdir -p "$LOGDIR"
now=$(date +%s)
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# Per-task maximum legitimate runtime (seconds). Bias HIGH: leaving an orphan a
# little longer is fine, killing a live run is not.
# Add one arm per schedule skill; anything not listed falls back to DEFAULT_MAX.
max_for_task(){
  case "$1" in
    commerce-cso-p1-investigation-skill) echo 2700 ;;   # 45 min — matches INVESTIGATION_TIMEOUT_MIN in slack-claude-bot/src/config.js
    *)                                    echo "$DEFAULT_MAX" ;;
  esac
}

# Epoch of a process's start time ("" if unavailable). Same normalization the
# registration step uses (see commerce-cso-p1-investigation-skill/SKILL.md Step 0),
# so values match for the same process.
epoch_of(){
  date -d "$(ps -o lstart= -p "$1" 2>/dev/null)" +%s 2>/dev/null
}

shopt -s nullglob
for reg in "$HOME"/.claude/scheduled-tasks/*/orphan-killer/registry.tsv; do
  [ -f "$reg" ] || continue
  proc="${reg}.proc.$$"
  mv "$reg" "$proc" 2>/dev/null || continue   # take ownership; concurrent appends land in a fresh reg
  surv="${reg}.surv.$$"; : > "$surv"

  while IFS=$'\t' read -r pid lse task; do
    [ -z "$pid" ] && continue
    case "$pid" in *[!0-9]*) continue ;; esac                 # non-numeric -> skip

    kill -0 "$pid" 2>/dev/null || continue                    # process gone -> prune
    comm=$(ps -o comm= -p "$pid" 2>/dev/null)
    [ "$comm" = "$CLAUDE_COMM" ] || continue                   # not a claude proc -> prune
    [ "$(epoch_of "$pid")" = "$lse" ] || continue             # PID recycled -> prune, NEVER kill

    # Confirmed: a live, registered scheduled session.
    max=$(max_for_task "$task")
    age=$(( now - lse ))

    # Early reap: the run has self-reported completion by appending a matching
    # pid+start-epoch row to completed.tsv as its last act. It is only lingering in
    # RAM now, so reap it immediately and skip the MAX_RUN wait. The guards above
    # (alive + claude binary + start-epoch match) already excluded a recycled PID, so
    # this never targets an unrelated process; we deliberately skip the budget here
    # because the explicit completion signal supersedes it.
    done_file="$(dirname "$reg")/completed.tsv"
    if [ -f "$done_file" ] && grep -qF "$(printf '%s\t%s\t' "$pid" "$lse")" "$done_file" 2>/dev/null; then
      if [ "$DRY_RUN" = 1 ]; then
        log "[dry-run] would early-reap $task pid=$pid age=${age}s (self-reported complete, ${max}s budget skipped)"
        printf '%s\t%s\t%s\n' "$pid" "$lse" "$task" >> "$surv"
      else
        if kill -9 "$pid" 2>/dev/null; then
          log "early-reaped $task pid=$pid age=${age}s (self-reported complete, skipped ${max}s budget)"
        else
          printf '%s\t%s\t%s\n' "$pid" "$lse" "$task" >> "$surv"   # kill failed -> keep
        fi
      fi
      continue
    fi

    if [ "$age" -lt "$max" ]; then
      printf '%s\t%s\t%s\n' "$pid" "$lse" "$task" >> "$surv"   # within budget -> protected
      continue
    fi

    # Past budget => a healthy live run would already have finished, so this is
    # completed or hung. Reap it.
    if [ "$DRY_RUN" = 1 ]; then
      log "[dry-run] would reap $task pid=$pid age=${age}s budget=${max}s (past budget)"
      printf '%s\t%s\t%s\n' "$pid" "$lse" "$task" >> "$surv"
    else
      if kill -9 "$pid" 2>/dev/null; then
        log "reaped $task pid=$pid age=${age}s (past ${max}s budget)"
      else
        printf '%s\t%s\t%s\n' "$pid" "$lse" "$task" >> "$surv"   # kill failed -> keep
      fi
    fi
  done < "$proc"

  [ -s "$surv" ] && cat "$surv" >> "$reg"     # preserve rows a concurrent run appended after our mv
  [ -f "$reg" ] && sort -u "$reg" -o "$reg" 2>/dev/null
  rm -f "$proc" "$surv"

  # Housekeeping: drop completed.tsv rows whose PID is gone (just reaped above, or the
  # run exited on its own). Keeps the early-reap signal file from growing unbounded.
  done_file="$(dirname "$reg")/completed.tsv"
  if [ -f "$done_file" ]; then
    dtmp="${done_file}.prune.$$"; : > "$dtmp"
    while IFS=$'\t' read -r dpid drest; do
      case "$dpid" in ''|*[!0-9]*) continue ;; esac
      kill -0 "$dpid" 2>/dev/null && printf '%s\t%s\n' "$dpid" "$drest" >> "$dtmp"
    done < "$done_file"
    mv "$dtmp" "$done_file" 2>/dev/null
  fi
done

exit 0
