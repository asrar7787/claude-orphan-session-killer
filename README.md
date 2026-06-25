# Claude Orphan Killer

A launchd agent that safely reaps **completed or hung headless Claude Code scheduled
sessions** — the ones that linger after finishing and waste RAM (~300–470 MB each) —
while **never** touching a live scheduled run or any interactive session.

---

## Why this exists

Headless Claude sessions spawned by Claude Desktop's scheduler don't always exit when
their turn completes — they sit idle holding their full RSS. At the process level
they're indistinguishable from *live* runs: every session shares the same binary,
arguments, environment (`CLAUDE_CODE_ENTRYPOINT=claude-desktop`), and working
directory. So a naive "kill idle headless sessions older than N minutes" rule would
eventually kill a live run that's simply waiting on a slow tool call.

The fix: each schedule **declares itself**, so the killer only ever acts on sessions
it can positively identify. Everything else is left strictly alone.

---

## How it works

**1. Schedules announce themselves.**
At the start of every run, a schedule appends its own PID and start-time to a
*registry* file; at the end of every run, it appends an "I'm done" marker to a
*completion* file. These two writes are the only way the killer learns a session
exists — interactive sessions never write them, so they're never touched. (The exact
snippets are in [How to install this script](#how-to-install-this-script).)

**2. The killer evaluates only registered PIDs.**
On each pass, for every registry entry the killer applies three **identity guards**.
Fail any one → the entry is skipped and pruned, **never** killed:

| Identity guard | Purpose |
|----------------|---------|
| process is alive | skip dead entries (pruned) |
| executable ends in `/claude.app/Contents/MacOS/claude` | confirm it really is a claude session |
| live start-epoch **matches** the registered one | PID-recycle guard — never kill a recycled PID |

**3. A surviving PID is reaped on whichever trigger comes first:**

- **Early reap** — the run left a matching completion marker, so it's finished and only
  lingering in RAM → reap now, ignoring the time budget.
- **Budget reap** — `age > MAX_RUN`. A healthy run finishes within its budget, so
  anything older is completed or hung → reap.

Otherwise the session keeps running. On a kill the killer sends `kill -9` and also
reaps the tiny `disclaimer` wrapper parent. **Unregistered processes (interactive
sessions, legacy orphans) are never candidates.**

> **Why two files (`registry.tsv` + `completed.tsv`)?** The killer rewrites
> `registry.tsv` to a strict 3-column schema on every pass. The completion marker has
> 5 columns, so storing it there would get the extra columns stripped and corrupt the
> task → budget lookup. Keeping them separate also lets the killer auto-prune
> completion rows once their PID is gone, so neither file grows unbounded.

---

## How to install this script

> Everything lives in `~/.claude/orphan-killer/`. The repo ships each file with a
> `.sample` suffix so nothing runs until you opt in.

### Step 1 — Activate the files and register your schedule skills

**a. Drop the `.sample` wording** from each shipped file to make it live:

```bash
cd ~/.claude/orphan-killer
cp kill-orphaned-claude.sample.sh  kill-orphaned-claude.sh
cp killer.log.sample               killer.log
cp launchd.err.log.sample          launchd.err.log
cp launchd.out.log.sample          launchd.out.log
chmod +x kill-orphaned-claude.sh
```

This gives you the real `kill-orphaned-claude.sh` plus the empty log files the agent
writes to. (Use `mv` instead of `cp` if you don't want to keep the samples around.)

**b. Register each schedule skill** in the `max_for_task()` function inside
`kill-orphaned-claude.sh`. The killer only acts on tasks it knows about, so add **one
`case` arm per schedule** — using the schedule's skill name (the same `<task-name>` it
registers under in Step 2) and a budget set **above that task's longest legitimate
run**:

```bash
max_for_task(){
  case "$1" in
    my-fast-task) echo 600  ;;   # 10 min — replace with your skill name + budget
    my-long-task) echo 2700 ;;   # 45 min
    # add more arms here, one per schedule skill...
    *)            echo "$DEFAULT_MAX" ;;   # anything unlisted → DEFAULT_MAX
  esac
}
```

A task with no arm still works (it falls back to `DEFAULT_MAX`), but an explicit arm
lets you tune its budget. The name must match exactly what the schedule writes into
`registry.tsv`.

### Step 2 — Make each schedule self-register

Add two snippets to every schedule's `SKILL.md` so it announces itself to the killer.

**Registration — the *first* action of every run** appends the session's PID and
start-time to its registry:

```bash
mkdir -p ~/.claude/scheduled-tasks/<task-name>/orphan-killer
LSE=$(date -j -f "%a %b %d %T %Y" "$(ps -o lstart= -p $PPID | tr -s ' ')" +%s 2>/dev/null)
printf '%s\t%s\t%s\n' "$PPID" "$LSE" "<task-name>" >> ~/.claude/scheduled-tasks/<task-name>/orphan-killer/registry.tsv
```

`$PPID` is the parent of the skill's Bash step — i.e. the `claude` session process
itself. The start-epoch doubles as a **PID-recycle fingerprint**. Registry line format
(tab-separated):

```
<pid>	<start-epoch>	<task-name>
```

**Completion marker — the *last* action of every run** (on *every* exit path,
including the empty "no new messages" poll and failure exits) tells the killer the run
is finished, so it can reap early instead of waiting out the full budget:

```bash
DONE_DIR=~/.claude/scheduled-tasks/<task-name>/orphan-killer
mkdir -p "$DONE_DIR"
LSE=$(date -j -f "%a %b %d %T %Y" "$(ps -o lstart= -p $PPID | tr -s ' ')" +%s 2>/dev/null)
COMPLETION_MSG="No new messages"   # ONE line, no tabs/newlines — short reason this run is done
printf '%s\t%s\t%s\t%s\t%s\n' "$PPID" "$LSE" "<task-name>" "$(date -u +%FT%TZ)" "$COMPLETION_MSG" >> "$DONE_DIR/completed.tsv"
```

Completion line format (tab-separated, 5 columns). The killer matches on columns 1–2
(`pid` + `start-epoch`); columns 3–5 are a human-readable record of which run finished
and why:

```
<pid>	<start-epoch>	<task-name>	<utc-iso>	<message>
```

### Step 3 — Configure and load the launchd agent

**Tune the killer** at the top of `kill-orphaned-claude.sh`:

| Setting | Default | Meaning |
|---------|---------|---------|
| `DEFAULT_MAX` | `1800` | fallback budget (seconds) for any task with no `max_for_task()` arm |

> **Budgets are the safety boundary.** Set each task's budget **above its longest
> legitimate run**. A live run that exceeds its budget *can* be reaped, so raising a
> budget is safe (an orphan just lingers a little longer) while lowering it risks
> killing a live run. With the Step 2 completion marker wired in, most runs are reaped
> early and never reach the budget anyway — it only matters for a run that crashes
> before writing its marker.

**Install the launchd agent** so the killer runs on a schedule. Create
`~/Library/LaunchAgents/com.YOUR_USER_NAME.claude-orphan-killer.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.YOUR_USER_NAME.claude-orphan-killer</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/Users/YOUR_USER_NAME/.claude/orphan-killer/kill-orphaned-claude.sh</string>
  </array>
  <key>StartInterval</key>
  <integer>300</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/Users/YOUR_USER_NAME/.claude/orphan-killer/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/YOUR_USER_NAME/.claude/orphan-killer/launchd.err.log</string>
</dict>
</plist>
```

`StartInterval` is the run cadence in seconds (300 = every 5 min). Then load it:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.YOUR_USER_NAME.claude-orphan-killer.plist

# after editing the plist later, reload with:
launchctl bootout   gui/$(id -u) ~/Library/LaunchAgents/com.YOUR_USER_NAME.claude-orphan-killer.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.YOUR_USER_NAME.claude-orphan-killer.plist
```

---

## Files & locations

| Path | What |
|------|------|
| `~/.claude/orphan-killer/kill-orphaned-claude.sh` | the killer script |
| `~/.claude/orphan-killer/killer.log` | one line per reap |
| `~/.claude/orphan-killer/launchd.out.log` / `.err.log` | launchd stdout / stderr |
| `~/Library/LaunchAgents/com.YOUR_USER_NAME.claude-orphan-killer.plist` | launchd agent (every 300 s, RunAtLoad) |
| `~/.claude/scheduled-tasks/<task>/orphan-killer/registry.tsv` | per-schedule live-session registry |
| `~/.claude/scheduled-tasks/<task>/orphan-killer/completed.tsv` | per-schedule early-reap completion markers |

---

## Safety model

- **Interactive sessions are never killed** — they never register, so they're never
  candidates.
- **Live scheduled runs are never killed** — a run emits its completion marker only
  *after* finishing all work; until then it's protected up to `MAX_RUN`, so keep each
  budget above the task's longest legitimate run.
- **Early reap is still guarded** — the alive + claude-binary + start-epoch checks run
  first, so a completion marker can never cause an unrelated or recycled PID to die.
- **PID recycling is handled** — the start-epoch fingerprint must match, so a recycled
  PID now belonging to another process is skipped.
- **The bias is deliberate** — a false negative (an orphan lingering a little longer) is
  acceptable; a false positive (killing a live run) is not. Every default leans toward
  not killing.

> **Note — completed sessions are not CPU-idle.** A finished headless session keeps a
> small keepalive tick (~1.5 % CPU from MCP/OTEL exporters and the event loop), so an
> "is the CPU flat?" idle test never fires. An earlier version tried to use CPU
> activity to tell completed sessions from live ones; it proved unreliable and was
> removed. Reaping is now purely **budget-based**: past `MAX_RUN` ⇒ reaped, full stop.

---

## Management

```bash
# watch reaps live
tail -f ~/.claude/orphan-killer/killer.log

# see what it WOULD do, without killing anything
DRY_RUN=1 /bin/bash ~/.claude/orphan-killer/kill-orphaned-claude.sh

# run once now
launchctl kickstart -k gui/$(id -u)/com.YOUR_USER_NAME.claude-orphan-killer

# is it loaded? (Status column = last exit code)
launchctl list | grep claude-orphan-killer

# pause / uninstall
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.YOUR_USER_NAME.claude-orphan-killer.plist
```

---

## Troubleshooting

- **Log empty / nothing killed** — usually correct: every registered session is within
  budget. Confirm with `DRY_RUN=1`. If a session you expect to die is past budget but
  spared, check its registry start-epoch matches `ps -o lstart=` (a mismatch is treated
  as a recycled PID and skipped).
- **A registry grows unbounded** — it shouldn't; the killer prunes dead/recycled entries
  and rewrites the file every run, while preserving rows appended mid-run.
- **A finished run lingers the full budget instead of reaping early** — its completion
  marker isn't reaching `completed.tsv`. Confirm the file has a row whose first two
  columns match the session's `pid` + start-epoch, and that the marker is written on
  *every* exit path (empty-poll and failure exits included).
- **A new schedule isn't being cleaned** — add the Step 2 registration and completion
  snippets to its `SKILL.md`, and optionally a `max_for_task()` arm; without an arm it
  falls back to `DEFAULT_MAX`.
