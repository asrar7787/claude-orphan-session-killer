# Claude Orphan Killer - Mac/Linux

A background agent that safely reaps **completed or hung headless Claude Code scheduled
sessions** — the ones that linger after finishing and waste RAM (~300–470 MB each) —
while **never** touching a live scheduled run or any interactive session.

This guide covers two platforms. On macOS the agent runs under `launchd`. On Linux
(Ubuntu 24.04) it runs under `systemd`. Jump to the section that matches your system.

---

## Why this exists

Headless Claude sessions spawned by a scheduler don't always exit when their turn
completes — they sit idle holding their full RSS. At the process level they're
indistinguishable from *live* runs: every session shares the same binary, arguments,
and working directory. So a naive "kill idle headless sessions older than N minutes"
rule would eventually kill a live run that's simply waiting on a slow tool call.

The fix: each schedule **declares itself**, so the killer only ever acts on sessions
it can positively identify. Everything else is left strictly alone.

---

## How it works

**1. Schedules announce themselves.**
At the start of every run, a schedule appends its own PID and start-time to a
*registry* file; at the end of every run, it appends an "I'm done" marker to a
*completion* file. These two writes are the only way the killer learns a session
exists — interactive sessions never write them, so they're never touched. (The exact
snippets are in the install steps below, for whichever platform you're setting up.)

**2. The killer evaluates only registered PIDs.**
On each pass, for every registry entry the killer applies three **identity guards**.
Fail any one → the entry is skipped and pruned, **never** killed:

| Identity guard | Purpose |
|----------------|---------|
| process is alive | skip dead entries (pruned) |
| executable matches the claude binary | confirm it really is a claude session |
| live start-epoch **matches** the registered one | PID-recycle guard — never kill a recycled PID |

**3. A surviving PID is reaped on whichever trigger comes first:**

- **Early reap** — the run left a matching completion marker, so it's finished and only
  lingering in RAM → reap now, ignoring the time budget.
- **Budget reap** — `age > MAX_RUN`. A healthy run finishes within its budget, so
  anything older is completed or hung → reap.

Otherwise the session keeps running. **Unregistered processes (interactive
sessions, legacy orphans) are never candidates.**

> **Why two files (`registry.tsv` + `completed.tsv`)?** The killer rewrites
> `registry.tsv` to a strict 3-column schema on every pass. The completion marker has
> 5 columns, so storing it there would get the extra columns stripped and corrupt the
> task → budget lookup. Keeping them separate also lets the killer auto-prune
> completion rows once their PID is gone, so neither file grows unbounded.

---

## How to install this script - Mac OS Bigsur/Sonoma/Sequoia

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

## How to install this script - Linux Ubuntu 24.04

> Everything lives in `~/.claude/orphan-killer/`. `kill-orphaned-claude.sh` is already
> written for GNU/Linux (GNU `date`, no macOS app-bundle paths) — no `.sample` renaming
> is needed here, unlike on macOS.

### Step 1 — Make the script executable and register your schedule skills

```bash
cd ~/.claude/orphan-killer
chmod +x kill-orphaned-claude.sh
```

`killer.log` doesn't need to be created ahead of time. The script creates it the first
time it actually reaps a session.

**Register each schedule skill** in the `max_for_task()` function inside
`kill-orphaned-claude.sh`, the same way as on macOS — one `case` arm per schedule, with
a budget set **above that task's longest legitimate run**:

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

Add two snippets to every schedule's `SKILL.md`, just like on macOS. Only the date
command changes — Linux uses GNU `date -d` instead of BSD `date -j -f`.

**Registration — the *first* action of every run** appends the session's PID and
start-time to its registry:

```bash
mkdir -p ~/.claude/scheduled-tasks/<task-name>/orphan-killer
LSE=$(date -d "$(ps -o lstart= -p $PPID)" +%s 2>/dev/null)
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
LSE=$(date -d "$(ps -o lstart= -p $PPID)" +%s 2>/dev/null)
COMPLETION_MSG="No new messages"   # ONE line, no tabs/newlines — short reason this run is done
printf '%s\t%s\t%s\t%s\t%s\n' "$PPID" "$LSE" "<task-name>" "$(date -u +%FT%TZ)" "$COMPLETION_MSG" >> "$DONE_DIR/completed.tsv"
```

Completion line format (tab-separated, 5 columns). The killer matches on columns 1–2
(`pid` + `start-epoch`); columns 3–5 are a human-readable record of which run finished
and why:

```
<pid>	<start-epoch>	<task-name>	<utc-iso>	<message>
```

### Step 3 — Configure and load the script as systemd service

**Tune the killer** at the top of `kill-orphaned-claude.sh`, same as on macOS:

| Setting | Default | Meaning |
|---------|---------|---------|
| `DEFAULT_MAX` | `1800` | fallback budget (seconds) for any task with no `max_for_task()` arm |

> **Budgets are the safety boundary.** Set each task's budget **above its longest
> legitimate run**. A live run that exceeds its budget *can* be reaped, so raising a
> budget is safe (an orphan just lingers a little longer) while lowering it risks
> killing a live run. With the Step 2 completion marker wired in, most runs are reaped
> early and never reach the budget anyway — it only matters for a run that crashes
> before writing its marker.

> **⚠️ Root access required for this step.** Ubuntu keeps unit files under
> `/etc/systemd/system/`, and only root can write there or run `systemctl
> daemon-reload` / `systemctl enable`. Regular users can't use `crontab` either
> unless an administrator has explicitly allowed it. If you don't have root on this
> box, ask someone who does to run the commands below.

**a. Create the service unit.** This defines what to run. Replace `YOUR_USER_NAME` and
the path with the account that owns `~/.claude`:

```bash
sudo tee /etc/systemd/system/claude-orphan-killer.service > /dev/null <<'EOF'
[Unit]
Description=Reap orphaned headless Claude Code sessions

[Service]
Type=oneshot
User=YOUR_USER_NAME
ExecStart=/bin/bash /home/YOUR_USER_NAME/.claude/orphan-killer/kill-orphaned-claude.sh
EOF
```

`User=YOUR_USER_NAME` makes systemd set `$HOME` to that user's home directory
automatically, so the script finds the right registry files without any extra
environment setup. `Type=oneshot` means systemd waits for one run to finish before it
can start the next — the timer below can never overlap two runs of the killer.

**b. Create the timer unit.** This defines when to run it:

```bash
sudo tee /etc/systemd/system/claude-orphan-killer.timer > /dev/null <<'EOF'
[Unit]
Description=Run claude-orphan-killer every 15 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Unit=claude-orphan-killer.service

[Install]
WantedBy=timers.target
EOF
```

`OnBootSec=2min` runs the first check 2 minutes after boot. `OnUnitActiveSec=15min`
repeats it every 15 minutes after that. Change this value if you want a different
cadence.

**c. Fix permissions and load both units:**

```bash
sudo chmod 644 /etc/systemd/system/claude-orphan-killer.service /etc/systemd/system/claude-orphan-killer.timer
sudo systemctl daemon-reload
sudo systemctl enable --now claude-orphan-killer.timer
```

`daemon-reload` tells systemd to read the new unit files. `enable --now` turns the
timer on immediately and keeps it enabled across reboots.

**d. Confirm it's running:**

```bash
systemctl list-timers | grep claude-orphan-killer
systemctl status claude-orphan-killer.service claude-orphan-killer.timer
```

The timer should show `active (waiting)` with a `NEXT`/time-left column, and the
service should show `code=exited, status=0/SUCCESS` after its first run.

---

## Files & locations

| Path | What |
|------|------|
| `~/.claude/orphan-killer/kill-orphaned-claude.sh` | the killer script |
| `~/.claude/orphan-killer/killer.log` | one line per reap |
| `~/.claude/orphan-killer/launchd.out.log` / `.err.log` | launchd stdout / stderr (macOS only) |
| `~/Library/LaunchAgents/com.YOUR_USER_NAME.claude-orphan-killer.plist` | launchd agent, macOS only (every 300 s, RunAtLoad) |
| `/etc/systemd/system/claude-orphan-killer.service` / `.timer` | systemd units, Linux only |
| `~/.claude/scheduled-tasks/<task>/orphan-killer/registry.tsv` | per-schedule live-session registry |
| `~/.claude/scheduled-tasks/<task>/orphan-killer/completed.tsv` | per-schedule early-reap completion markers |

---

## Safety model - Mac OS Bigsur/Sonoma/Sequoia

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
- **A second pass catches runs that die before they can register.** A schedule run that
  hits the account's weekly usage limit fails on its very first model call, before it
  can write to `registry.tsv` at all. Claude Desktop logs this failure to
  `~/Library/Logs/Claude/main.log` with a session id, and that session's "Starting
  local session" line shares its second with the process's OS start time. The killer
  matches on that shared second and reaps a live `auto`-mode PID only if *every*
  session that started at that second hit a hard quota limit — a healthy run that
  merely shares the second is left alone. Set `WEEKLY_LIMIT_REAP=0` to disable this
  pass.

> **Note — completed sessions are not CPU-idle.** A finished headless session keeps a
> small keepalive tick (~1.5 % CPU from MCP/OTEL exporters and the event loop), so an
> "is the CPU flat?" idle test never fires. An earlier version tried to use CPU
> activity to tell completed sessions from live ones; it proved unreliable and was
> removed. Reaping is now purely **budget-based**: past `MAX_RUN` ⇒ reaped, full stop.

## Safety model - Linux Ubuntu 24.04

The core guards are the same as macOS — registration-only, alive + identity +
start-epoch checks, budget-based reaping, no CPU-idle heuristic. A few things work
differently on this platform:

- **Identity check uses `comm`, not an app-bundle path.** On Linux the Claude Code
  binary isn't inside an app bundle, so the killer confirms a PID is really a claude
  process by checking `ps -o comm=` equals `claude`, which stays stable across
  version upgrades even though the resolved binary path (under
  `~/.local/share/claude/versions/...`) changes with each release.
- **Start-epoch uses GNU `date -d`.** The macOS build relies on `date -j -f`, a BSD-only
  flag that GNU `date` (Ubuntu's default) doesn't support. Using the wrong flag here
  would silently break the PID-recycle check on every session, so this is not
  interchangeable between platforms.
- **No weekly-usage-limit second pass.** That mechanism depends on Claude Desktop's
  `~/Library/Logs/Claude/main.log` and its `disclaimer` helper process, neither of
  which exists in a headless Linux deployment where sessions are spawned directly by
  a Node process (or similar) via `child_process.spawn`. A session that fails before
  registering is instead caught by whatever timeout the calling process enforces —
  make sure that caller has its own timeout, since the killer can't see a session
  that never wrote to `registry.tsv`.
- **`systemd` adds its own safety net.** `Type=oneshot` guarantees one run of the
  killer finishes before the timer can start the next, so two copies never race on
  the same registry file. Because the unit files live under `/etc/systemd/system/`,
  only root can change the schedule or the command it runs — a non-root compromise of
  the account being monitored can't disable or retarget the killer.

---

## Management - Mac OS Bigsur/Sonoma/Sequoia

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

## Management - Linux Ubuntu 24.04

```bash
# watch reaps live
tail -f ~/.claude/orphan-killer/killer.log

# see what it WOULD do, without killing anything
DRY_RUN=1 /bin/bash ~/.claude/orphan-killer/kill-orphaned-claude.sh

# run once now, without waiting for the next scheduled tick (root required)
sudo systemctl start claude-orphan-killer.service

# check the schedule and when it last/next ran
systemctl list-timers | grep claude-orphan-killer

# check the last run's result
sudo systemctl status claude-orphan-killer.service

# read the script's own stdout/stderr for a given run (root required for other users' logs)
sudo journalctl -u claude-orphan-killer.service --since -1h

# pause it without deleting anything (root required)
sudo systemctl stop claude-orphan-killer.timer

# resume it later (root required)
sudo systemctl start claude-orphan-killer.timer

# uninstall completely (root required)
sudo systemctl disable --now claude-orphan-killer.timer
sudo rm /etc/systemd/system/claude-orphan-killer.service /etc/systemd/system/claude-orphan-killer.timer
sudo systemctl daemon-reload
```

---

## Troubleshooting - Mac OS Bigsur/Sonoma/Sequoia

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

## Troubleshooting - Linux Ubuntu 24.04

- **`systemctl enable --now` fails with "Unit file ... does not exist"** — the
  `.service` or `.timer` file wasn't actually created at
  `/etc/systemd/system/`. Check both files exist with
  `ls -la /etc/systemd/system/claude-orphan-killer.*` before retrying.
- **`Job failed. See "journalctl -xe" for details."`** — check
  `systemctl status claude-orphan-killer.service claude-orphan-killer.timer`. A
  `Loaded: bad-setting` result usually means the unit file's contents got mangled —
  for example, extra text pasted in above or below the `[Service]` block by mistake.
  Recreate the file with only the `[Unit]` / `[Service]` (or `[Timer]` / `[Install]`)
  sections shown in Step 3, nothing else.
- **Can't read a unit file to check its contents** — unit files should be `644`
  (world-readable). If a file was created `600` (root-only), fix it with
  `sudo chmod 644 /etc/systemd/system/claude-orphan-killer.*` and reload with
  `sudo systemctl daemon-reload`.
- **Nothing ever gets reaped** — confirm the identity check can actually match a live
  session: run `ps -o pid,comm -p <pid>` on a known headless session and make sure
  `comm` prints exactly `claude`. If it prints something else, update `CLAUDE_COMM`
  at the top of `kill-orphaned-claude.sh` to match.
- **A new schedule isn't being cleaned** — add the Step 2 registration and completion
  snippets to its `SKILL.md`, and optionally a `max_for_task()` arm; without an arm it
  falls back to `DEFAULT_MAX`.
