# Drive Usage Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 15-min sampling of per-drive I/O from `/proc/diskstats` plus an on-demand report (hour-of-day heatmap + idle-run summary) to inform a future `hdparm` spindown decision.

**Architecture:** Two new bash scripts in `scripts/` plus a cron file in `config/`, all sourcing `/etc/nas-management.conf`. Sampler maintains a state file holding previous cumulative counters; logs deltas to a CSV. Report parses the CSV with `awk`. No new package dependency — `/proc/diskstats`, `awk`, `date` are all that's needed.

**Tech Stack:** bash, `awk`, `/proc/diskstats`, cron. No tests — this repo has no test framework (CLAUDE.md: "all scripts are plain bash, manually tested"). Each implementation task includes manual-verification steps with expected output.

---

## File Structure

```
scripts/
  drive-usage-sample            (new — cron sampler, ~50 lines bash)
  drive-usage-report            (new — on-demand reporter, awk-driven)
config/
  cron-drive-usage              (new — */15 cron entry)
  nas-management.conf           (modify — add 2 path variables)
README.md                       (modify — new section + install + inventory)
```

Each script is self-contained and small enough to live in a single file. The repo's existing convention is one script per command.

---

## Spec Reference

Working from `docs/superpowers/specs/2026-04-27-drive-usage-monitoring-design.md`. Read it before starting if you haven't.

---

### Task 1: Add config variables

**Files:**
- Modify: `config/nas-management.conf`

- [ ] **Step 1: Append the two new path variables**

Open `config/nas-management.conf` and append at end of file:

```bash
DRIVE_USAGE_LOG="/home/$NAS_USER/.drive-usage.log"
DRIVE_USAGE_STATE="/home/$NAS_USER/.drive-usage-state"
```

These follow the same convention as `ALERT_FILE` and `BACKUP_STATUS_FILE`.

- [ ] **Step 2: Verify the file still parses**

Run: `bash -n config/nas-management.conf`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add config/nas-management.conf
git commit -m "Add drive-usage log and state paths to shared config"
```

---

### Task 2: Implement `drive-usage-sample`

**Files:**
- Create: `scripts/drive-usage-sample`

- [ ] **Step 1: Write the script**

Create `scripts/drive-usage-sample` with this exact content:

```bash
#!/bin/bash
# Sample per-drive I/O over the last interval.
# Cumulative-counter diff vs /proc/diskstats; called every 15 min by cron.

set -u
source /etc/nas-management.conf

LOG="$DRIVE_USAGE_LOG"
STATE="$DRIVE_USAGE_STATE"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%S)

# Ensure log has a CSV header on first ever run
if [ ! -f "$LOG" ]; then
    if ! echo "timestamp,drive,read_bytes,write_bytes" > "$LOG"; then
        echo "drive-usage-sample: cannot write log header to $LOG" >&2
        exit 1
    fi
fi

# Read /proc/diskstats once into a single snapshot used for all drives
if ! DISKSTATS=$(cat /proc/diskstats); then
    echo "drive-usage-sample: cannot read /proc/diskstats" >&2
    exit 1
fi

# Load previous counters into associative arrays, validating numeric format
declare -A PREV_READ PREV_WRITE
if [ -f "$STATE" ]; then
    while read -r drive r w; do
        [ -z "$drive" ] && continue
        if ! [[ "$r" =~ ^[0-9]+$ ]] || ! [[ "$w" =~ ^[0-9]+$ ]]; then
            echo "drive-usage-sample: malformed state for $drive: '$r' '$w'" >&2
            exit 1
        fi
        PREV_READ["$drive"]=$r
        PREV_WRITE["$drive"]=$w
    done < "$STATE"
fi

# Build new state beside the live state for atomic same-filesystem rename.
# mktemp with a randomized suffix avoids clobber from a stray concurrent run.
if ! NEW_STATE=$(mktemp "${STATE}.tmp.XXXXXX"); then
    echo "drive-usage-sample: cannot create temp state file beside $STATE" >&2
    exit 1
fi
# mktemp creates 0600; relax to 0644 so the final state file matches the rest
# of the repo's user-home dotfiles. The mode is carried through the mv.
chmod 0644 "$NEW_STATE"
trap 'rm -f "$NEW_STATE"' EXIT

# shellcheck disable=SC2086
for dev_path in $DISK_DEVICES; do
    drive=$(basename "$dev_path")

    # If drive is currently absent, preserve previous state entry untouched
    if [ ! -b "$dev_path" ]; then
        prev_r=${PREV_READ["$drive"]:-}
        prev_w=${PREV_WRITE["$drive"]:-}
        if [ -n "$prev_r" ]; then
            if ! echo "$drive $prev_r $prev_w" >> "$NEW_STATE"; then
                echo "drive-usage-sample: cannot append to temp state file" >&2
                exit 1
            fi
        fi
        continue
    fi

    # Look up this drive in the snapshot; field 3 = name, 6 = sectors read, 10 = sectors written
    read -r cur_read cur_write < <(awk -v d="$drive" '$3 == d {print $6, $10; exit}' <<< "$DISKSTATS")
    if [ -z "${cur_read:-}" ]; then
        continue
    fi

    prev_r=${PREV_READ["$drive"]:-}
    prev_w=${PREV_WRITE["$drive"]:-}

    # Log a row only when we have a usable previous sample (counters monotonic)
    if [ -n "$prev_r" ] && [ -n "$prev_w" ] \
       && [ "$cur_read" -ge "$prev_r" ] \
       && [ "$cur_write" -ge "$prev_w" ]; then
        delta_r=$(( (cur_read - prev_r) * 512 ))
        delta_w=$(( (cur_write - prev_w) * 512 ))
        if ! echo "$TIMESTAMP,$drive,$delta_r,$delta_w" >> "$LOG"; then
            echo "drive-usage-sample: cannot append to $LOG" >&2
            exit 1
        fi
    fi

    if ! echo "$drive $cur_read $cur_write" >> "$NEW_STATE"; then
        echo "drive-usage-sample: cannot append to temp state file" >&2
        exit 1
    fi
done

if ! mv "$NEW_STATE" "$STATE"; then
    echo "drive-usage-sample: failed to commit state update ($NEW_STATE -> $STATE)" >&2
    exit 1
fi
trap - EXIT
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/drive-usage-sample`
Expected: no output.

- [ ] **Step 3: Lint**

Run: `bash -n scripts/drive-usage-sample`
Expected: no output, exit 0.

If `shellcheck` is available: `shellcheck scripts/drive-usage-sample` — should pass cleanly aside from the existing `# shellcheck disable=SC2086` (deliberate, mirrors `disk-check`).

- [ ] **Step 4: Manual verification on NAS — first run writes state, no log row**

On the NAS (after copying script into `/usr/local/bin/`):

```bash
sudo cp scripts/drive-usage-sample /usr/local/bin/
sudo chmod +x /usr/local/bin/drive-usage-sample
sudo cp config/nas-management.conf /etc/nas-management.conf  # only if changed
# Make sure no stale state/log exist from earlier testing
sudo rm -f ~/.drive-usage.log ~/.drive-usage-state
sudo /usr/local/bin/drive-usage-sample
cat ~/.drive-usage.log
cat ~/.drive-usage-state
```

Expected:
- `~/.drive-usage.log` contains only the header row: `timestamp,drive,read_bytes,write_bytes`
- `~/.drive-usage-state` contains 4 lines, one per drive (sda, sdb, sdc, sdd), each with two large numeric counters.

- [ ] **Step 5: Manual verification on NAS — second run produces a delta row**

```bash
sleep 5
sudo /usr/local/bin/drive-usage-sample
cat ~/.drive-usage.log
```

Expected: the log now has 4 additional rows (one per drive) with current UTC timestamp, drive name, and bytes (likely small — only 5s elapsed). All four drives should appear; values may be 0 if no I/O happened.

- [ ] **Step 6: Commit**

```bash
git add scripts/drive-usage-sample
git commit -m "Add drive-usage-sample: 15-min /proc/diskstats sampler"
```

---

### Task 3: Add cron entry

**Files:**
- Create: `config/cron-drive-usage`

- [ ] **Step 1: Write the cron file**

Create `config/cron-drive-usage` with exactly this content:

```
# Drive usage sampling - every 15 minutes
*/15 * * * * root /usr/local/bin/drive-usage-sample
```

- [ ] **Step 2: Verify file mode and content**

Run: `cat config/cron-drive-usage`
Expected: the two lines above. No trailing whitespace issues — cron files in `/etc/cron.d/` are sensitive.

- [ ] **Step 3: Commit**

```bash
git add config/cron-drive-usage
git commit -m "Add cron entry to sample drive usage every 15 minutes"
```

---

### Task 4: Implement `drive-usage-report`

**Files:**
- Create: `scripts/drive-usage-report`

- [ ] **Step 1: Write the script**

Create `scripts/drive-usage-report` with this exact content:

```bash
#!/bin/bash
# On-demand report: hour-of-day activity heatmap + idle-run summary.
# Reads ~/.drive-usage.log produced by drive-usage-sample.

set -u
set -o pipefail
source /etc/nas-management.conf

LOG="$DRIVE_USAGE_LOG"
MIN_TICKS=96  # 1 day × 96 samples (15-min interval)

# Missing log is the trivial zero-data case
if [ ! -f "$LOG" ]; then
    echo "Not enough data yet — collected 0 samples; recommend waiting for at least 1 day."
    exit 0
fi

# Drive list in config order (alphabetical from /dev/sd[a-d] glob)
DRIVE_LIST=""
# shellcheck disable=SC2086
for dev_path in $DISK_DEVICES; do
    DRIVE_LIST="$DRIVE_LIST $(basename "$dev_path")"
done

# Snapshot the data so a concurrent cron append can't desync the two passes.
DATA_FILE=$(mktemp) || { echo "drive-usage-report: cannot create temp file" >&2; exit 1; }
HOURS_FILE=$(mktemp) || { echo "drive-usage-report: cannot create temp file" >&2; exit 1; }
trap 'rm -f "$DATA_FILE" "$HOURS_FILE"' EXIT
tail -n +2 "$LOG" > "$DATA_FILE"

# Count unique timestamp ticks — same unit the report's "Collected: N samples"
# footer uses, so the guard message and the footer can never disagree on the
# same data. (CSV row count would be ticks × n_drives.)
TICK_COUNT=$(awk -F, '{seen[$1]=1} END {n=0; for (k in seen) n++; print n+0}' "$DATA_FILE")
if [ "$TICK_COUNT" -lt "$MIN_TICKS" ]; then
    echo "Not enough data yet — collected $TICK_COUNT samples; recommend waiting for at least 1 day."
    exit 0
fi

# Per-row UTC→localtime conversion via a single batch `date -f -` invocation.
# Correct across DST transitions — each timestamp is converted in its own right,
# unlike a single `date +%z` snapshot which would bake one fixed offset into
# rows that span a transition.
#
# Emit "<local-hour>,<epoch-seconds>" per line so the awk pass can both bucket
# by hour and detect missing-sample gaps (idle runs must not span them).
if ! awk -F, '{ts=$1; sub(/T/," ",ts); print ts " UTC"}' "$DATA_FILE" \
        | date -f - "+%H,%s" > "$HOURS_FILE"; then
    echo "drive-usage-report: timestamp conversion failed (date -f -)" >&2
    exit 1
fi

# Defence in depth: paste only works correctly when both files have the same
# row count. A short HOURS_FILE would silently mis-align the columns.
data_lines=$(wc -l < "$DATA_FILE")
hour_lines=$(wc -l < "$HOURS_FILE")
if [ "$data_lines" -ne "$hour_lines" ]; then
    echo "drive-usage-report: timestamp conversion produced $hour_lines lines for $data_lines data rows" >&2
    exit 1
fi

# Paste the local-hour + epoch columns onto the data rows, then process in awk.
paste -d, "$HOURS_FILE" "$DATA_FILE" | awk -F, \
    -v drive_list="$DRIVE_LIST" '
function record_run(drive, len) {
    if (len > longest[drive]) longest[drive] = len
    if (len*15 >= 60)  count_1h[drive]++
    if (len*15 >= 120) count_2h[drive]++
    if (len*15 >= 240) count_4h[drive]++
}
BEGIN {
    n_drives = split(drive_list, drives, " ")
}
{
    # $1=local hour, $2=epoch seconds, $3=ts (UTC), $4=drive, $5=read_bytes, $6=write_bytes
    h = $1 + 0; epoch = $2 + 0; ts = $3; drive = $4; rb = $5 + 0; wb = $6 + 0
    active = (rb + wb > 0) ? 1 : 0

    # Heatmap accumulator
    bucket_total[drive, h]++
    if (active) bucket_active[drive, h]++

    # Gap detection: a missing cron tick or absent-drive interval must break
    # the idle run. Tolerance of one minute over the nominal 15-min cadence.
    if ((drive in last_epoch) && epoch - last_epoch[drive] > 16*60) {
        if (current_run[drive] > 0) {
            record_run(drive, current_run[drive])
            current_run[drive] = 0
        }
    }

    if (active) {
        if (current_run[drive] > 0) {
            record_run(drive, current_run[drive])
            current_run[drive] = 0
        }
    } else {
        current_run[drive]++
    }

    last_epoch[drive] = epoch
    date_part = substr(ts, 1, 10)
    if (first_date == "" || date_part < first_date) first_date = date_part
    if (date_part > last_date) last_date = date_part
    samples_seen[ts] = 1
    days_seen[date_part] = 1
}
END {
    for (d in current_run) {
        if (current_run[d] > 0) record_run(d, current_run[d])
    }

    n_samples = 0; for (t in samples_seen) n_samples++
    n_days = 0;    for (d in days_seen)    n_days++

    # ---- Heatmap ----
    printf "Hour-of-day activity (%% of samples with I/O):\n\n"
    printf "      "
    for (i = 1; i <= n_drives; i++) printf " %4s", drives[i]
    printf "\n"
    for (hr = 0; hr < 24; hr++) {
        printf "  %02d  ", hr
        for (i = 1; i <= n_drives; i++) {
            d = drives[i]
            tot = bucket_total[d, hr] + 0
            act = bucket_active[d, hr] + 0
            pct = (tot == 0) ? 0 : int(act * 100 / tot + 0.5)
            printf " %4d", pct
        }
        printf "\n"
    }
    printf "\nCollected: %s to %s (%d days, %d samples)\n\n", \
        first_date, last_date, n_days, n_samples

    # ---- Idle runs ----
    printf "Idle runs (consecutive 15-min windows with no I/O):\n\n"
    for (i = 1; i <= n_drives; i++) {
        d = drives[i]
        l = longest[d] + 0
        printf "  %s:  longest %dh%02dm | runs >=1h: %d | >=2h: %d | >=4h: %d\n", \
            d, int(l*15/60), (l*15)%60, count_1h[d]+0, count_2h[d]+0, count_4h[d]+0
    }
}
'
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/drive-usage-report`
Expected: no output.

- [ ] **Step 3: Lint**

Run: `bash -n scripts/drive-usage-report`
Expected: no output, exit 0.

- [ ] **Step 4: Manual verification — empty/short log path**

On the NAS, with a fresh empty log (only the header) or fewer than 96 unique timestamp ticks:

```bash
sudo cp scripts/drive-usage-report /usr/local/bin/
sudo chmod +x /usr/local/bin/drive-usage-report
/usr/local/bin/drive-usage-report
```

Expected: `Not enough data yet — collected <N> samples; recommend waiting for at least 1 day.` Exit 0.

- [ ] **Step 5: Manual verification — full output path against synthetic fixture**

To verify the heatmap and idle-run formatting without waiting a day, swap in a synthetic log at the canonical path (the script's `source /etc/nas-management.conf` overrides any env vars, so we can't redirect with `DRIVE_USAGE_LOG=...`).

```bash
# Back up any real log first
[ -f ~/.drive-usage.log ] && cp ~/.drive-usage.log ~/.drive-usage.log.bak

# Build fixture: 4 drives × 96 samples × 2 days = 768 rows; sda busy at 02:00 UTC, others quiet
{
    echo "timestamp,drive,read_bytes,write_bytes"
    for day in 26 27; do
        for h in $(seq -f "%02g" 0 23); do
            for m in 00 15 30 45; do
                ts="2026-04-${day}T${h}:${m}:00"
                for d in sda sdb sdc sdd; do
                    rb=0; wb=0
                    if [ "$d" = "sda" ] && [ "$h" = "02" ]; then rb=131072; wb=8192; fi
                    echo "${ts},${d},${rb},${wb}"
                done
            done
        done
    done
} > ~/.drive-usage.log

/usr/local/bin/drive-usage-report

# Restore (or remove) the real log
if [ -f ~/.drive-usage.log.bak ]; then
    mv ~/.drive-usage.log.bak ~/.drive-usage.log
else
    rm -f ~/.drive-usage.log
fi
```

Expected:
- Heatmap shows `100` at hour 02 for `sda` (or 03 if you're in BST/CEST — localtime conversion is what we're verifying), `0` everywhere else for `sda`, all `0` for `sdb`/`sdc`/`sdd`.
- Idle-run summary: `sdb`/`sdc`/`sdd` show longest of `48h00m` (the full fixture), all run-counts populated. `sda` shows shorter runs separated by its busy hour.
- "Collected: 2026-04-26 to 2026-04-27 (2 days, 192 samples)".

- [ ] **Step 6: Commit**

```bash
git add scripts/drive-usage-report
git commit -m "Add drive-usage-report: hour-of-day heatmap and idle-run summary"
```

---

### Task 5: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a new "Drive Usage Monitoring" section between "Disk Monitoring" and "Backup System"**

Locate the line containing `## Backup System` in `README.md`. Insert the following block immediately *before* that line (with one blank line separating from the preceding section). The outer fence below is four backticks so the inner triple-backtick CSV example is preserved verbatim — when pasting into README, drop the outer four-backtick fence and keep the inner triple-backtick block intact.

````markdown
## Drive Usage Monitoring

A 15-minute sampler that captures per-drive I/O activity over time, intended to inform an `hdparm` spindown decision. Run it for one to two weeks, then read `drive-usage-report` and choose a timeout (or decide spindown isn't worthwhile).

### How It Works

Every 15 minutes, cron runs `drive-usage-sample`. The script reads cumulative read/write counters for `sda`–`sdd` from `/proc/diskstats`, diffs them against the previous run's values stored in `~/.drive-usage-state`, and appends one CSV row per drive to `~/.drive-usage.log`:

```
timestamp,drive,read_bytes,write_bytes
2026-04-27T14:15:00,sda,0,0
2026-04-27T14:15:00,sdb,131072,8192
...
```

Timestamps are UTC (avoids DST shifts mid-collection); the report converts to localtime per-row when bucketing by hour. No `sysstat`/`iostat` dependency — `/proc/diskstats` exposes the same counters.

### Commands

| Command | Description |
|---------|-------------|
| `drive-usage-report` | Show hour-of-day heatmap and idle-run summary |
| `drive-usage-sample` | 15-min sampler — invoked by cron, not run manually |

### Reading the Report

Two views:
- **Hour-of-day heatmap:** % of samples with any I/O, by hour (localtime). Reveals quiet windows.
- **Idle-run summary:** longest no-I/O run per drive plus counts of runs >=1h, >=2h, >=4h. Tells you whether a candidate `hdparm` timeout would actually catch idle time.

If a drive shows many >=2h idle runs, a spindown of ~30 min would catch real idle time. If it never gets a >=1h run, spindown isn't worthwhile for that drive.
````

- [ ] **Step 2: Update the install snippet — extend the `chmod +x` line**

Find this line in the "Scripts → `/usr/local/bin/`" section:

```bash
sudo chmod +x /usr/local/bin/backup-* /usr/local/bin/disk-* /usr/local/bin/smartd-notify.sh /usr/local/bin/mdadm-notify.sh /usr/local/bin/mdcheck-notify.sh
```

Replace with:

```bash
sudo chmod +x /usr/local/bin/backup-* /usr/local/bin/disk-* /usr/local/bin/drive-usage-* /usr/local/bin/smartd-notify.sh /usr/local/bin/mdadm-notify.sh /usr/local/bin/mdcheck-notify.sh
```

- [ ] **Step 3: Update the cron install snippet**

Find the "### Cron" subsection. After the existing `cron-backup` install lines, append:

```bash
sudo cp config/cron-drive-usage /etc/cron.d/drive-usage
sudo chmod 644 /etc/cron.d/drive-usage
```

- [ ] **Step 4: Update the file inventory**

Find the `scripts/` block in the "## File Inventory" section. Add these two lines (preserving the existing alignment style of two-space indent and column-padded descriptions):

```
  drive-usage-sample     15-min /proc/diskstats sampler (cron)
  drive-usage-report     Hour-of-day and idle-run report
```

In the `config/` block, add:

```
  cron-drive-usage       Cron job for 15-min drive sampling
```

- [ ] **Step 5: Verify the rendered README looks reasonable**

Run: `grep -n "Drive Usage" README.md`
Expected: matches in the new section heading and the file inventory.

Run: `grep -nE 'drive-usage-(sample|report)' README.md`
Expected: >=4 matches (section text, commands table, install snippet, file inventory).

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "Document drive usage monitoring in README"
```

---

## Final Verification

Once all tasks are complete:

- [ ] `git log --oneline -6` shows the five new commits in order (config, sampler, cron, report, README).
- [ ] `ls scripts/drive-usage-*` shows both new scripts, both executable.
- [ ] On the NAS: install the updated config, scripts, and cron file. After two `*/15` ticks from a fresh install (≤30 min), `wc -l < ~/.drive-usage.log` shows 5 (header + first 4 data rows — tick 1 only seeds state, tick 2 produces the first deltas). After three ticks: 9 lines.
- [ ] After 24 hours of collection, `drive-usage-report` produces both views without "Not enough data" message.

Spindown configuration is **not** part of this plan. Review the report after a week or two of data and decide separately.
