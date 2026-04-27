# Drive Usage Monitoring — Design

**Date:** 2026-04-27
**Status:** Design approved, awaiting implementation plan

## Purpose

Capture per-drive I/O activity over 1–2 weeks so the operator can decide whether to configure `hdparm` spindown timeouts on the NAS data drives, and at what value. Configuring spindown itself is **out of scope** — this design covers only data collection and reporting.

## Architecture

Two new bash scripts plus a cron entry, matching existing repo patterns (`scripts/` → `/usr/local/bin/`, `config/` → `/etc/...`, sourcing `/etc/nas-management.conf`).

```
cron (every 15 min)
  └─ drive-usage-sample
       ├─ reads /proc/diskstats
       ├─ reads/writes ~/.drive-usage-state   (last cumulative counters)
       └─ appends to ~/.drive-usage.log       (per-drive deltas)

operator (on demand)
  └─ drive-usage-report
       └─ reads ~/.drive-usage.log → heatmap + idle-run summary
```

No daemon, no systemd timer, no new package dependency. `/proc/diskstats` is in every Linux kernel; `awk` and `date` cover everything else.

## Data Source

`/proc/diskstats`. Each line has fields:

```
major minor name reads_completed reads_merged sectors_read read_ms
                writes_completed writes_merged sectors_written write_ms
                ...
```

Field 6 (`sectors_read`) and field 10 (`sectors_written`) are monotonically-increasing cumulative counters. Multiply by 512 to get bytes. The diff between two reads of these fields gives total I/O over the interval.

`iostat`/`sysstat` is **not** used. It exposes the same kernel counters with a friendlier formatter but adds a package dependency for no extra information.

## Log File: `~/.drive-usage.log`

CSV, append-only, **long format** (one row per drive per sample):

```csv
timestamp,drive,read_bytes,write_bytes
2026-04-27T14:15:00,sda,0,0
2026-04-27T14:15:00,sdb,4096,0
2026-04-27T14:15:00,sdc,0,0
2026-04-27T14:15:00,sdd,131072,8192
2026-04-27T14:30:00,sda,0,0
...
```

- **Timestamp:** UTC ISO-8601 (`date -u +%Y-%m-%dT%H:%M:%S`). UTC avoids DST shifts mid-collection corrupting hour-of-day analysis. The report converts to localtime when bucketing.
- **Format choice:** long format means a drive added or removed later doesn't shift columns and break parsing of older rows.
- **Volume:** 96 samples/day × 4 drives × ~50 bytes/row ≈ 20 KB/day. Two weeks ≈ 280 KB. No rotation needed.
- **Path:** sourced from `DRIVE_USAGE_LOG` in `/etc/nas-management.conf`.

## State File: `~/.drive-usage-state`

Plain text, one drive per line, holds previous cumulative counters from `/proc/diskstats` (raw sectors, not bytes):

```
sda 12345678 9876543
sdb 23456789 1234567
sdc 0 0
sdd 45678901 2345678
```

- **Format:** `<drive> <read_sectors> <write_sectors>`, space-separated.
- **Updated atomically:** sample script writes to `<state>.tmp`, then renames over the live file.
- **Path:** sourced from `DRIVE_USAGE_STATE` in `/etc/nas-management.conf`.

## Sampler: `drive-usage-sample`

Runs every 15 min from cron. Flow:

1. `source /etc/nas-management.conf` — pulls in `NAS_USER`, `DISK_DEVICES`, `DRIVE_USAGE_LOG`, `DRIVE_USAGE_STATE`.
2. Read `/proc/diskstats` once into a variable (single snapshot, used for all drives).
3. For each device matching `$DISK_DEVICES` (`/dev/sd[a-d]` glob — same expansion `disk-check` uses):
   - If device file doesn't exist (`[ -b "$dev" ]` false), skip — handles a drive being absent or pulled.
   - Look up the drive's row in the diskstats snapshot. Extract field 6 (sectors read) and field 10 (sectors written).
   - Look up previous counters for this drive in the state file (parsed once at script start).
   - **No previous entry** (first run for this drive): record state, log nothing this cycle.
   - **Counter went down** (drive re-enumerated, e.g. USB reseat or suspend): record fresh state, log nothing this cycle.
   - **Otherwise:** compute delta in sectors, multiply by 512, append `timestamp,drive,read_bytes,write_bytes` to the log, record fresh state.
4. Write the new state map atomically (`<state>.tmp` → `mv`).

**Locking:** none. Work is bounded (one file read, two file writes); no risk of overlapping ticks.

**Failure mode:** the script exits non-zero on any of:
- `/proc/diskstats` can't be read,
- state file malformed (non-numeric counter values),
- temp state file can't be created beside `$STATE`,
- log header / log row / temp-state-row write fails (full disk, read-only mount),
- final `mv "$NEW_STATE" "$STATE"` fails.

Cron emails root on non-zero exit. The next tick recovers because state is rewritten on each successful run. Silent success on a failed state update is explicitly avoided so a broken backup drive or readonly home wouldn't masquerade as a healthy collection.

## Report: `drive-usage-report`

On-demand, no arguments, prints to stdout. Implemented as `awk` over the CSV plus a single batch invocation of GNU `date -f -` to convert each row's UTC timestamp to localtime (per-row conversion is required so rows that span a DST transition bucket into the correct local hour). GNU `date` is part of `coreutils` on the target Debian-family NAS, so this adds no new package dependency — but the report does require GNU `date` semantics, not POSIX-only.

### View 1 — Hour-of-day heatmap

Percentage of samples per hour bucket (across all collected days) with any non-zero I/O. "Activity" = `read_bytes + write_bytes > 0`. Hours converted from UTC timestamps to localtime when bucketing.

```
Hour-of-day activity (% of samples with I/O):

       sda  sdb  sdc  sdd
  00     2    0    0    0
  01     0    0    0    0
  02   100  100  100  100
  03    14    0    0    0
  ...
  14    71   29   14    0
  ...

Collected: 2026-04-15 to 2026-04-27 (12 days, 1152 samples)
```

### View 2 — Idle-run summary

A "run" is a sequence of consecutive samples with zero activity for a given drive. Run length is reported in 15-min units converted to `Hh MMm`.

**Gap-aware accumulation.** A "consecutive sample" requires the previous logged sample for that drive to be no more than ~16 minutes earlier (allowing 1 min of cron jitter on the nominal 15-min cadence). Larger gaps — caused by cron outages, NAS reboots, or a drive being absent for some ticks — break the run. Without this, two zero-activity rows surrounding a multi-tick gap would be conflated into one inflated idle stretch. The report enriches each row with epoch seconds (via `date -f - "+%H,%s"`) so awk can compute per-drive sample-to-sample deltas.

```
Idle runs (consecutive 15-min windows with no I/O):

  sda:  longest 4h15m | runs >=1h: 18 | >=2h: 7 | >=4h: 2
  sdb:  longest 9h30m | runs >=1h: 24 | >=2h: 14 | >=4h: 9
  sdc:  longest 11h00m | runs >=1h: 26 | >=2h: 17 | >=4h: 12
  sdd:  longest 11h00m | runs >=1h: 26 | >=2h: 17 | >=4h: 12
```

Thresholds 1h / 2h / 4h correspond to plausible hdparm timeout choices: many >=2h runs argues for a 30-min spindown; zero >=1h runs argues against any spindown for that drive.

### Empty / short log

If `$DRIVE_USAGE_LOG` doesn't exist or covers fewer than 96 unique timestamps (1 day × 96 samples), print:

```
Not enough data yet — collected <N> samples; recommend waiting for at least 1 day.
```

…and exit 0. The threshold and the report's `Collected: ... samples` line both use the same unit (unique timestamp ticks), so the two never disagree on the same data.

## Configuration Changes

Add to `config/nas-management.conf`:

```bash
DRIVE_USAGE_LOG="/home/$NAS_USER/.drive-usage.log"
DRIVE_USAGE_STATE="/home/$NAS_USER/.drive-usage-state"
```

`DISK_DEVICES` already covers `/dev/sd[a-d]` and is reused unchanged. Backup drive (`sdf`) is not in `DISK_DEVICES`, so it's automatically excluded.

## Cron Entry

`config/cron-drive-usage`:

```
# Drive usage sampling - every 15 minutes
*/15 * * * * root /usr/local/bin/drive-usage-sample
```

Installed to `/etc/cron.d/drive-usage` with mode 644 (matching `cron-backup`).

## README Additions

A new section between **Disk Monitoring** and **Backup System** titled **Drive Usage Monitoring** with:

- Purpose: inform `hdparm` spindown decisions.
- Mechanism: 15-min cumulative-counter diff, log + state file paths.
- Note: deliberately uses `/proc/diskstats` only — no `sysstat`/`iostat` dependency.
- Commands table:

  | Command | Description |
  |---|---|
  | `drive-usage-report` | Hour-of-day heatmap and idle-run summary |
  | `drive-usage-sample` | 15-min sampler — invoked by cron, not run manually |

- Install snippet: `cp` and `chmod` for the two scripts, `cp` of cron file.
- File inventory: append the new files.

`drive-usage-report` is **not** added to `.zshrc` — it's diagnostic, not at-a-glance status.

## Out of Scope

- **Configuring `hdparm`.** That's a manual decision the operator makes after reviewing one or two weeks of report output. The data tells them whether and at what timeout it's worthwhile; the choice itself doesn't belong in this design.
- **Log rotation.** Volume is too small to matter for the diagnostic timeframe.
- **Alerting on activity patterns.** This is a one-time investigation tool, not an ongoing monitor.

## Risks / Edge Cases

- **DST during collection** — mitigated by storing UTC timestamps and only converting to localtime at report time.
- **USB drive re-enumeration** changing counter direction — explicitly handled (counter < previous → reset state, log nothing).
- **A monitored drive is absent at sample time** — `[ -b "$dev" ]` skip; the drive's previous state entry is left untouched. When the drive returns, the counter-reset branch (current < previous) handles re-enumeration cleanly; if the kernel happened to preserve counters across the absence, the delta is simply the I/O that occurred while the drive was present.
- **First-ever run** — no state file: write counters, log nothing. First real data point lands 15 min later.
- **Cron not delivering email on script failure** — acceptable; the next successful run repairs state, and missing log rows are visible in the report's sample count.
