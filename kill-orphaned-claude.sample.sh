#!/bin/bash

# Author: Asrar Alam
# License: MIT
#
# claude-orphan-session-killer  (TEMPLATE)
# This is a placeholder copy of kill-orphaned-claude.sh. Replace the example task
# names in max_for_task() below with your own schedule skill names before using it.
#
# Purpose: Reap completed or hung headless Claude Code sessions that belong to
# self-registering scheduled tasks, while never touching anything else.
#
# Safety model:
#   * Only PIDs found in a schedule's own registry are ever candidates.
#     Interactive Cowork sessions never register -> are never killed.
#   * Identity guards (fail any one -> skip and prune the entry, NEVER kill):
#       - it is still alive
#       - its executable is the claude binary
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
CLAUDE_SUFFIX="/claude.app/Contents/MacOS/claude"
DISCLAIMER="/Applications/Claude.app/Contents/Helpers/disclaimer"

LOGDIR="$HOME/.claude/orphan-killer"
LOG="$LOGDIR/killer.log"
mkdir -p "$LOGDIR"
now=$(date +%s)
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# Per-task maximum legitimate runtime (seconds). Bias HIGH: leaving an orphan a
# little longer is fine, killing a live run is not.
# Replace these example arms with your own schedule skill names; anything not
# listed falls back to DEFAULT_MAX.
max_for_task(){
  case "$1" in
    my-fast-task) echo 600  ;;   # 10 min
    my-long-task) echo 2700 ;;   # 45 min
    *)            echo "$DEFAULT_MAX" ;;
  esac
}

# Epoch of a process's start time ("" if unavailable). Same normalization the
# registration step uses, so values match for the same process.
epoch_of(){
  date -j -f "%a %b %d %T %Y" "$(ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ')" +%s 2>/dev/null
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
    case "$comm" in *"$CLAUDE_SUFFIX") ;; *) continue ;; esac  # not a claude proc -> prune
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
        ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        if kill -9 "$pid" 2>/dev/null; then
          log "early-reaped $task pid=$pid age=${age}s (self-reported complete, skipped ${max}s budget)"
          [ "$(ps -o comm= -p "$ppid" 2>/dev/null)" = "$DISCLAIMER" ] && kill -9 "$ppid" 2>/dev/null
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
      ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      if kill -9 "$pid" 2>/dev/null; then
        log "reaped $task pid=$pid age=${age}s (past ${max}s budget)"
        [ "$(ps -o comm= -p "$ppid" 2>/dev/null)" = "$DISCLAIMER" ] && kill -9 "$ppid" 2>/dev/null
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
