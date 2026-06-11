# Drive-usage Stable Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-key the drive-usage sampler and report on each disk's stable `ID_SERIAL_SHORT` instead of its kernel letter, so the historical log can't blend two physical disks when device letters reorder across a reboot.

**Architecture:** `drive-usage-sample` keeps using the kernel name only for the inherently letter-keyed `/proc/diskstats` lookup, but writes the serial as the identity in both `~/.drive-usage.log` and `~/.drive-usage-state`. `drive-usage-report` aggregates by serial internally and resolves each serial back to its current `/dev/sdX` for friendly column headers, printing a `legend:` line that maps letter→serial. The CSV header changes from `drive` to `serial`, so the existing header-mismatch guard auto-rotates stale letter-keyed logs.

**Tech Stack:** Bash, awk, `udevadm` (serial resolution), `/proc/diskstats`, `hdparm`. No test framework — this repo is plain bash, verified with `bash -n`, `shellcheck`, and synthetic-log render runs (per CLAUDE.md).

**Reference spec:** `docs/superpowers/specs/2026-06-10-drive-usage-stable-identity-design.md` — read it before starting.

---

## File Structure

- Modify: `scripts/drive-usage-sample` — serial resolver; key log + state by serial; new header; drop absent-drive branch.
- Modify: `scripts/drive-usage-report` — serial resolver + serial→letter map; drive set from log serials; serial-keyed awk with letter labels + legend; new header.
- Modify: `README.md` — sampler description, example CSV block, report-reading wording.

No new files. No config or cron changes (`DISK_DEVICES` already self-resolves from `/proc/mdstat`).

---

## Task 1: Re-key `drive-usage-sample` on serial

**Files:**
- Modify: `scripts/drive-usage-sample`

- [ ] **Step 1: Change the expected CSV header**

Replace the header constant (the `drive` column becomes `serial`):

```sh
EXPECTED_HEADER="timestamp,serial,read_bytes,write_bytes,power_state"
```

(Old value: `timestamp,drive,read_bytes,write_bytes,power_state`.)

- [ ] **Step 2: Re-key the state-load loop on the stable id**

Find this block:

```sh
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
```

Replace it with (the state key is now an opaque id — rename the loop var for clarity):

```sh
declare -A PREV_READ PREV_WRITE
if [ -f "$STATE" ]; then
    while read -r id r w; do
        [ -z "$id" ] && continue
        if ! [[ "$r" =~ ^[0-9]+$ ]] || ! [[ "$w" =~ ^[0-9]+$ ]]; then
            echo "drive-usage-sample: malformed state for $id: '$r' '$w'" >&2
            exit 1
        fi
        PREV_READ["$id"]=$r
        PREV_WRITE["$id"]=$w
    done < "$STATE"
fi
```

- [ ] **Step 3: Replace the per-drive loop body — resolve serial, key on it, drop the absent branch**

Find the whole `for dev_path in $DISK_DEVICES; do … done` loop:

```sh
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

        # `hdparm -C` reports the drive's power state without spinning it up,
        # unlike smartctl. Possible values: active/idle, standby, sleeping,
        # unknown. Fall back to "unknown" if hdparm is missing or fails.
        power_state=$(hdparm -C "$dev_path" 2>/dev/null | awk '/drive state is:/ {print $NF; exit}')
        [ -z "$power_state" ] && power_state="unknown"

        if ! echo "$TIMESTAMP,$drive,$delta_r,$delta_w,$power_state" >> "$LOG"; then
            echo "drive-usage-sample: cannot append to $LOG" >&2
            exit 1
        fi
    fi

    if ! echo "$drive $cur_read $cur_write" >> "$NEW_STATE"; then
        echo "drive-usage-sample: cannot append to temp state file" >&2
        exit 1
    fi
done
```

Replace the entire loop with:

```sh
# shellcheck disable=SC2086
for dev_path in $DISK_DEVICES; do
    kname=$(basename "$dev_path")

    # Persistent identity is the drive's stable serial, NOT its kernel letter:
    # letters reorder across reboots, which would blend two physical disks in
    # the historical log. Prefer ID_SERIAL_SHORT (matches 99-nas-spindown.rules),
    # fall back to ID_WWN, then to a clearly-degraded kname-<letter> so a
    # serial-less drive is flagged rather than silently masquerading as stable.
    serial=$(udevadm info -q property -n "$dev_path" 2>/dev/null | sed -n 's/^ID_SERIAL_SHORT=//p')
    [ -z "$serial" ] && serial=$(udevadm info -q property -n "$dev_path" 2>/dev/null | sed -n 's/^ID_WWN=//p')
    [ -z "$serial" ] && { serial="kname-$kname"; echo "drive-usage-sample: no serial for $kname, using $serial" >&2; }

    # Look up this drive in the snapshot by kernel name (diskstats is letter-keyed);
    # field 3 = name, 6 = sectors read, 10 = sectors written. An absent drive has
    # no row here and is skipped — no separate [ -b ] branch needed.
    read -r cur_read cur_write < <(awk -v d="$kname" '$3 == d {print $6, $10; exit}' <<< "$DISKSTATS")
    if [ -z "${cur_read:-}" ]; then
        continue
    fi

    prev_r=${PREV_READ["$serial"]:-}
    prev_w=${PREV_WRITE["$serial"]:-}

    # Log a row only when we have a usable previous sample (counters monotonic)
    if [ -n "$prev_r" ] && [ -n "$prev_w" ] \
       && [ "$cur_read" -ge "$prev_r" ] \
       && [ "$cur_write" -ge "$prev_w" ]; then
        delta_r=$(( (cur_read - prev_r) * 512 ))
        delta_w=$(( (cur_write - prev_w) * 512 ))

        # `hdparm -C` reports the drive's power state without spinning it up,
        # unlike smartctl. Possible values: active/idle, standby, sleeping,
        # unknown. Fall back to "unknown" if hdparm is missing or fails.
        power_state=$(hdparm -C "$dev_path" 2>/dev/null | awk '/drive state is:/ {print $NF; exit}')
        [ -z "$power_state" ] && power_state="unknown"

        if ! echo "$TIMESTAMP,$serial,$delta_r,$delta_w,$power_state" >> "$LOG"; then
            echo "drive-usage-sample: cannot append to $LOG" >&2
            exit 1
        fi
    fi

    if ! echo "$serial $cur_read $cur_write" >> "$NEW_STATE"; then
        echo "drive-usage-sample: cannot append to temp state file" >&2
        exit 1
    fi
done
```

- [ ] **Step 4: Syntax check**

Run: `bash -n scripts/drive-usage-sample`
Expected: no output, exit 0.

- [ ] **Step 5: Lint**

Run: `shellcheck scripts/drive-usage-sample`
Expected: clean, except the pre-existing `# shellcheck disable=SC2086` on the `DISK_DEVICES` loop (deliberate, mirrors `disk-check`). No new warnings. (Skip if `shellcheck` is not installed — note that in the commit.)

- [ ] **Step 6: Commit**

```bash
git add scripts/drive-usage-sample
git commit -m "drive-usage-sample: key log and state on ID_SERIAL_SHORT, not kernel letter"
```

---

## Task 2: Re-key `drive-usage-report` on serial with letter labels

**Files:**
- Modify: `scripts/drive-usage-report`

- [ ] **Step 1: Change the expected CSV header**

Replace the header constant:

```sh
EXPECTED_HEADER="timestamp,serial,read_bytes,write_bytes,power_state"
```

(Old value: `timestamp,drive,read_bytes,write_bytes,power_state`.)

- [ ] **Step 2: Remove the old letter-based DRIVE_LIST block**

Delete this block entirely (it runs before the data snapshot and keys on current letters):

```sh
# Drive list from DISK_DEVICES (the RAID member disks, resolved in the config)
DRIVE_LIST=""
# shellcheck disable=SC2086
for dev_path in $DISK_DEVICES; do
    DRIVE_LIST="$DRIVE_LIST $(basename "$dev_path")"
done

```

- [ ] **Step 3: Build the serial set, letter labels, and legend after the tick guard**

The drive set must come from the serials actually present in the log, and labels come from the *current* serial→letter mapping. Insert this block immediately AFTER the `TICK_COUNT` guard (the `if [ "$TICK_COUNT" -lt "$MIN_TICKS" ]; then … fi` block) and BEFORE the `awk -F, '{ ts=$1; …` localtime conversion:

```sh
# Map each currently-attached drive's serial to its kernel letter, so the report
# can show friendly sda-style headers while keying aggregation on the stable
# serial. Same resolver as drive-usage-sample (ID_SERIAL_SHORT → ID_WWN → kname).
declare -A SERIAL_TO_LETTER
# shellcheck disable=SC2086
for dev_path in $DISK_DEVICES; do
    kname=$(basename "$dev_path")
    s=$(udevadm info -q property -n "$dev_path" 2>/dev/null | sed -n 's/^ID_SERIAL_SHORT=//p')
    [ -z "$s" ] && s=$(udevadm info -q property -n "$dev_path" 2>/dev/null | sed -n 's/^ID_WWN=//p')
    [ -z "$s" ] && s="kname-$kname"
    SERIAL_TO_LETTER["$s"]="$kname"
done

# Serials present in the log (column 2). Order: currently-attached drives first,
# sorted by their kernel letter; then any since-replaced serials (no current
# letter), sorted by serial — so a swapped-out disk still shows its history.
LOG_SERIALS=$(awk -F, '{print $2}' "$DATA_FILE" | sort -u)
present_ordered=$(
    for s in $LOG_SERIALS; do
        l=${SERIAL_TO_LETTER["$s"]:-}
        [ -n "$l" ] && echo "$l $s"
    done | sort | awk '{print $2}'
)
absent_ordered=$(
    for s in $LOG_SERIALS; do
        [ -z "${SERIAL_TO_LETTER["$s"]:-}" ] && echo "$s"
    done | sort
)

# SERIAL_LIST = aggregation keys (serials); LABEL_LIST = display headers (current
# letter when attached, else the bare serial); LEGEND maps letter→serial for the
# attached drives only (absent columns show the serial directly, so need no key).
SERIAL_LIST=""
LABEL_LIST=""
LEGEND=""
legend_sep=""
for s in $present_ordered; do
    l=${SERIAL_TO_LETTER["$s"]}
    SERIAL_LIST="$SERIAL_LIST $s"
    LABEL_LIST="$LABEL_LIST $l"
    LEGEND="$LEGEND$legend_sep$l=$s"
    legend_sep=", "
done
for s in $absent_ordered; do
    SERIAL_LIST="$SERIAL_LIST $s"
    LABEL_LIST="$LABEL_LIST $s"
done
```

- [ ] **Step 4: Pass the serial keys, labels, and legend into awk**

Find the awk invocation header:

```sh
paste -d, "$HOURS_FILE" "$DATA_FILE" | awk -F, \
    -v drive_list="$DRIVE_LIST" '
```

Replace it with:

```sh
paste -d, "$HOURS_FILE" "$DATA_FILE" | awk -F, \
    -v serial_list="$SERIAL_LIST" -v label_list="$LABEL_LIST" -v legend="$LEGEND" '
```

- [ ] **Step 5: Split both lists in awk BEGIN**

Find:

```awk
BEGIN {
    n_drives = split(drive_list, drives, " ")
}
```

Replace with (`drives[i]` stays the aggregation key — now a serial; `labels[i]` is the matching display header):

```awk
BEGIN {
    n_drives = split(serial_list, drives, " ")
    split(label_list, labels, " ")
}
```

The body keys `bucket_total[drive, h]`, `current_run[drive]`, `spinups[drive]` etc. on `drive = $4`, which is now the serial — no change needed there; the serial is column 2 of the log and lands in `$4` after the hour/epoch paste, exactly where `drive` was.

- [ ] **Step 6: Print the legend and use labels for the activity heatmap header**

Find the activity-heatmap header:

```awk
    printf "Hour-of-day activity (%% of samples with I/O):\n\n"
    printf "      "
    for (i = 1; i <= n_drives; i++) printf " %4s", drives[i]
    printf "\n"
```

Replace with:

```awk
    printf "Hour-of-day activity (%% of samples with I/O):\n\n"
    if (legend != "") printf "  legend: %s\n\n", legend
    printf "      "
    for (i = 1; i <= n_drives; i++) printf " %4s", labels[i]
    printf "\n"
```

- [ ] **Step 7: Use labels in the idle-run summary**

Find:

```awk
    for (i = 1; i <= n_drives; i++) {
        d = drives[i]
        l = longest[d] + 0
        printf "  %s:  longest %dh%02dm | runs >=1h: %d | >=2h: %d | >=4h: %d\n", \
            d, int(l*15/60), (l*15)%60, count_1h[d]+0, count_2h[d]+0, count_4h[d]+0
    }
```

Replace with (key lookups stay on `d` = serial; the printed name becomes `labels[i]`):

```awk
    for (i = 1; i <= n_drives; i++) {
        d = drives[i]
        l = longest[d] + 0
        printf "  %s:  longest %dh%02dm | runs >=1h: %d | >=2h: %d | >=4h: %d\n", \
            labels[i], int(l*15/60), (l*15)%60, count_1h[d]+0, count_2h[d]+0, count_4h[d]+0
    }
```

- [ ] **Step 8: Use labels for the standby heatmap header**

Find the standby-heatmap header:

```awk
    printf "\nHour-of-day standby (%% of samples parked):\n\n"
    printf "      "
    for (i = 1; i <= n_drives; i++) printf " %4s", drives[i]
    printf "\n"
```

Replace with:

```awk
    printf "\nHour-of-day standby (%% of samples parked):\n\n"
    printf "      "
    for (i = 1; i <= n_drives; i++) printf " %4s", labels[i]
    printf "\n"
```

- [ ] **Step 9: Use labels in the spin-up summary**

Find:

```awk
    for (i = 1; i <= n_drives; i++) {
        d = drives[i]
        total = spinups[d] + 0
        per_day = (n_days > 0) ? (total / n_days) : 0
        printf "  %s:  total %d over %d days (%.1f/day)\n", d, total, n_days, per_day
    }
```

Replace with:

```awk
    for (i = 1; i <= n_drives; i++) {
        d = drives[i]
        total = spinups[d] + 0
        per_day = (n_days > 0) ? (total / n_days) : 0
        printf "  %s:  total %d over %d days (%.1f/day)\n", labels[i], total, n_days, per_day
    }
```

- [ ] **Step 10: Syntax check**

Run: `bash -n scripts/drive-usage-report`
Expected: no output, exit 0.

- [ ] **Step 11: Lint**

Run: `shellcheck scripts/drive-usage-report`
Expected: clean except the pre-existing/added `# shellcheck disable=SC2086` on the `DISK_DEVICES` loop. No new warnings. (Skip if `shellcheck` absent — note in commit.)

- [ ] **Step 12: Render test against a synthetic serial-keyed log**

This exercises the awk aggregation, ordering, and the absent-drive fallback. The script hard-codes `source /etc/nas-management.conf` and reads the log from the canonical path, so run this where the config is installed (the NAS, or any box with `/etc/nas-management.conf` present) and place the fixture at `~/.drive-usage.log`. The fixture's `SER-*` serials won't match the box's real drives, so `SERIAL_TO_LETTER` has no entry for them and every column renders as "absent" — bare-serial headers, no `legend:` line. That fully validates the serial keying, ordering, and counts. The live letter-label + legend path (real serials → current letters) is validated in Task 4.

```bash
# Back up any real log first
[ -f ~/.drive-usage.log ] && cp ~/.drive-usage.log ~/.drive-usage.log.bak

# Build fixture: 3 serials × 96 samples × 2 days = 576 rows.
# SER-A busy at 02:00 UTC (and parked otherwise); SER-B/SER-C always quiet+parked.
{
    echo "timestamp,serial,read_bytes,write_bytes,power_state"
    for day in 09 10; do
        for h in $(seq -f "%02g" 0 23); do
            for m in 00 15 30 45; do
                ts="2026-06-${day}T${h}:${m}:00"
                for s in SER-A SER-B SER-C; do
                    rb=0; wb=0; ps=standby
                    if [ "$s" = "SER-A" ] && [ "$h" = "02" ]; then rb=131072; wb=8192; ps=active/idle; fi
                    echo "${ts},${s},${rb},${wb},${ps}"
                done
            done
        done
    done
} > ~/.drive-usage.log

/usr/local/bin/drive-usage-report 2>/dev/null || bash scripts/drive-usage-report

# Restore (or remove) the real log
if [ -f ~/.drive-usage.log.bak ]; then
    mv ~/.drive-usage.log.bak ~/.drive-usage.log
else
    rm -f ~/.drive-usage.log
fi
```

Expected (on a host with no `udevadm` mapping — columns are the bare serials, no `legend:` line):
- Activity heatmap: `SER-A` shows `100` at hour 02 (or 03 under BST — localtime conversion), `0` elsewhere; `SER-B`/`SER-C` all `0`.
- Column order: `SER-A SER-B SER-C` (all absent → sorted by serial).
- `Collected: 2026-06-09 to 2026-06-10 (2 days, 192 samples)`.
- Idle runs: `SER-B`/`SER-C` longest `48h00m`; `SER-A` shorter runs split by its busy hour.
- Standby heatmap: `SER-B`/`SER-C` near `100` every hour; `SER-A` `0` at hour 02.
- Spin-up events: `SER-A` shows transitions standby→active/idle (2 over 2 days, one per busy morning); `SER-B`/`SER-C` `0`.

- [ ] **Step 13: Confirm the header guard rejects an old letter-keyed log**

```bash
[ -f ~/.drive-usage.log ] && cp ~/.drive-usage.log ~/.drive-usage.log.bak
printf 'timestamp,drive,read_bytes,write_bytes,power_state\n2026-06-09T00:00:00,sda,0,0,standby\n' > ~/.drive-usage.log
./scripts/drive-usage-report; echo "exit=$?"
if [ -f ~/.drive-usage.log.bak ]; then mv ~/.drive-usage.log.bak ~/.drive-usage.log; else rm -f ~/.drive-usage.log; fi
```

Expected: a `log header mismatch` error naming the expected `…,serial,…` header and a `rotate to upgrade: rm` line; `exit=1`.

- [ ] **Step 14: Commit**

```bash
git add scripts/drive-usage-report
git commit -m "drive-usage-report: aggregate by serial, show current letter + legend"
```

---

## Task 3: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Reword the sampler description**

Find (in the "How It Works" paragraph):

```
Every 15 minutes, cron runs `drive-usage-sample`. The script reads cumulative read/write counters for `sda`–`sdd` from `/proc/diskstats`, diffs them against the previous run's values stored in `~/.drive-usage-state`, queries each drive's power state via `hdparm -C` (which does not spin the drive up, unlike `smartctl`), and appends one CSV row per drive to `~/.drive-usage.log`:
```

Replace with:

```
Every 15 minutes, cron runs `drive-usage-sample`. For each RAID member disk (resolved from `/proc/mdstat`), the script reads cumulative read/write counters from `/proc/diskstats`, diffs them against the previous run's values stored in `~/.drive-usage-state`, queries the drive's power state via `hdparm -C` (which does not spin the drive up, unlike `smartctl`), and appends one CSV row per drive to `~/.drive-usage.log`. Each row is keyed by the drive's stable serial (`ID_SERIAL_SHORT`), not its `sdX` letter — kernel letters reorder across reboots, which would otherwise blend two physical disks in the historical log:
```

- [ ] **Step 2: Update the example CSV block**

Find:

```
timestamp,drive,read_bytes,write_bytes,power_state
2026-04-27T14:15:00,sda,0,0,standby
2026-04-27T14:15:00,sdb,131072,8192,active/idle
...
```

Replace with:

```
timestamp,serial,read_bytes,write_bytes,power_state
2026-04-27T14:15:00,WD-WCC4E1H8KP2L,0,0,standby
2026-04-27T14:15:00,WD-WCC4E2J9NR7M,131072,8192,active/idle
...
```

- [ ] **Step 3: Note that the report resolves serials back to letters**

Find the "Reading the Report" intro line:

```
Four views:
```

Replace with:

```
The report aggregates by serial but resolves each one back to its current `/dev/sdX` for the column headers, with a `legend:` line mapping letter→serial above the heatmaps. A drive no longer attached (e.g. swapped out) keeps its history under its serial, shown in place of a letter. Four views:
```

- [ ] **Step 4: Verify the edits landed and no stale `,drive,` header remains**

Run: `grep -n 'timestamp,serial,\|ID_SERIAL_SHORT.*not its\|resolves each one back' README.md`
Expected: matches for the new header line, the sampler rewording, and the report-reading note.

Run: `grep -n 'timestamp,drive,' README.md`
Expected: no output (the old example header is gone).

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "README: document serial-keyed drive-usage log and letter/legend report"
```

---

## Task 4: On-NAS verification (manual, on the Linux box)

This validates the live `udevadm` resolution and the letter+legend display path, which can't run on a dev Mac. Run after deploying the updated scripts.

- [ ] **Step 1: Deploy the updated scripts**

```bash
sudo cp scripts/drive-usage-sample scripts/drive-usage-report /usr/local/bin/
sudo chmod +x /usr/local/bin/drive-usage-sample /usr/local/bin/drive-usage-report
```

- [ ] **Step 2: Rotate the now-incompatible log and re-seed state**

The header guard will reject the old letter-keyed log; rotate both files so the new serial-keyed format starts clean.

```bash
rm -f ~/.drive-usage.log ~/.drive-usage-state
sudo /usr/local/bin/drive-usage-sample            # tick 1: seeds serial-keyed state
cat ~/.drive-usage-state
```

Expected: `~/.drive-usage-state` has one line per RAID member disk, each beginning with the drive's **serial** (not `sda`), followed by two large numeric counters.

- [ ] **Step 3: Confirm log rows are serial-keyed**

```bash
sleep 1; sudo /usr/local/bin/drive-usage-sample   # tick 2: first deltas
cat ~/.drive-usage.log
```

Expected: header `timestamp,serial,read_bytes,write_bytes,power_state`, then data rows whose second field is each drive's serial.

- [ ] **Step 4: Confirm the report shows letters + legend**

Run after ≥24h of collection (or temporarily lower `MIN_TICKS` for a smoke check, then restore):

Run: `/usr/local/bin/drive-usage-report`
Expected: a `legend: sda=<serial>, sdb=<serial>, …` line above the activity heatmap; heatmap/idle/standby/spin-up sections use the `sdX` letters as column headers and row labels, matching the current array ordering.

---

## Self-Review Notes

- **Spec coverage:** Identifier+resolver (T1.S3, T2.S3), sampler serial keying + dropped absent branch (T1), report serial aggregation + letter labels + legend + log-serial drive set + ordering (T2), header/migration (T1.S1, T2.S1, T2.S13), README (T3), testing incl. absent-drive fallback and guard rejection (T2.S12–13, T4). The dated 2026-04-27 docs are intentionally left unedited per the spec.
- **Type/name consistency:** awk uses `drives[i]` (serial key) and `labels[i]` (display header) consistently across all four print sections; bash uses `SERIAL_LIST`/`LABEL_LIST`/`LEGEND` matching the `-v serial_list/label_list/legend` awk vars; resolver var is `serial` in the sampler and `s` in the report's map loop (no cross-reference between them).
- **Known accepted cosmetic edge:** an absent drive's bare serial is wider than the `%4s` heatmap column and will misalign that one column. Accepted (rare; only after a disk swap) per the spec's display choice.
