# Drive-usage stable identity — design

**Date:** 2026-06-10
**Status:** Approved (design)

## Problem

The drive-usage monitoring system (`drive-usage-sample` → `~/.drive-usage.log` →
`drive-usage-report`) records each drive's identity as its **kernel letter**
(`sda`, `sdb`, …). Kernel device letters can reorder across reboots, so a
physical disk that was `sdb` before a reboot may be `sdc` after.

The rest of the repo was already made letter-independent: `BACKUP_DEVICE` uses
`/dev/disk/by-id`, `smartd.conf` lists drives by `by-id`/transport,
`99-nas-spindown.rules` keys on `ID_SERIAL_SHORT`, and `DISK_DEVICES` re-resolves
from `/proc/mdstat` on every run. The diskstats sampler is the one straggler
still using the kernel letter as a *persistent* key.

`DISK_DEVICES` resolving correctly each run actually *hides* the problem: the
sampler keeps appending rows under a letter whose meaning has changed, so
`drive-usage-report` aggregates the historical time series by a column that is
not stable. Two physical disks blend into one heatmap column / idle-run stat /
spin-up count across a reboot boundary, and one disk's history splits across two
labels. Nothing errors — the numbers silently become a blend, which is the worst
failure mode for a per-drive wear/idle tracker.

(The cumulative-counter reset on reboot is already handled: `cur_read >= prev_r`
fails when `/proc/diskstats` resets low after boot, so the first post-boot sample
is skipped. Only the *identity*, not the counters, is unsafe.)

## Goal

Make the persistent drive identity stable across reboots and hardware reorders,
consistent with the rest of the repo, without losing the operator-friendly
`sda`-style labels in the report.

## Identifier and resolution

Persistent identity becomes **`ID_SERIAL_SHORT`**, matching
`99-nas-spindown.rules`. A kernel name is mapped to its serial at runtime:

```sh
serial=$(udevadm info -q property -n "/dev/$kname" 2>/dev/null | sed -n 's/^ID_SERIAL_SHORT=//p')
[ -z "$serial" ] && serial=$(udevadm info -q property -n "/dev/$kname" 2>/dev/null | sed -n 's/^ID_WWN=//p')
[ -z "$serial" ] && { serial="kname-$kname"; echo "<script>: no serial for $kname, using $serial" >&2; }
```

- Prefer `ID_SERIAL_SHORT`; fall back to `ID_WWN`; last resort `kname-<kname>`
  with a stderr warning so a serial-less drive is visibly flagged rather than
  silently masquerading as stable.
- The NAS's SATA array drives all expose serials, so the fallbacks are defensive
  only.
- The resolver is inlined in both scripts (~5 lines each) rather than expanding
  `nas-management.conf` from variables-only into hosting shell functions.

The kernel letter is still used for the `/proc/diskstats` lookup itself — that
table is inherently letter-keyed (field 3 is the kernel name). Only the
*identity written to the log and state file* changes to the serial.

## Sampler: `drive-usage-sample`

- For each `dev_path` in `DISK_DEVICES`: `kname=$(basename "$dev_path")` is used
  to look up `/proc/diskstats`; `serial` (from the resolver) is the identity.
- Log rows become `<timestamp>,<serial>,<delta_r>,<delta_w>,<power_state>`.
- State file lines become `<serial> <read> <write>`.
- **State migration:** none needed. The state file is rewritten in full every
  run, so it self-heals to serial keys after one tick — old letter-keyed `prev`
  entries simply won't match the new serial lookups, so each drive is re-seeded
  (skipping one row, exactly like a fresh install).
- **Absent-drive branch removed.** An absent drive can't be probed for its
  serial, and `DISK_DEVICES` comes from `/proc/mdstat` (present members by
  definition), so the previous "preserve prev state for an absent drive" logic
  is dropped rather than kept as dead/unreachable code. A drive whose
  `/proc/diskstats` row is missing is still skipped via the existing
  `[ -z "${cur_read:-}" ]` guard.

## Report: `drive-usage-report`

- Build a `serial → current-letter` map by walking current `DISK_DEVICES`
  (letter = basename, serial = resolver).
- The drive set is taken from **the serials present in the log**, not from
  current `DISK_DEVICES`, so a since-replaced disk still shows its history
  instead of vanishing or colliding with a reused letter.
- Ordering: drives currently present first (sorted by current letter), then any
  absent serials (sorted by serial).
- Column header = current letter when the serial maps to a present drive, else
  the bare serial. A `legend: sda=<serial>, …` line prints once above each
  heatmap so the letter↔serial mapping is explicit.
- The awk aggregation keys on **serial** internally — the serial field is
  column 2 of the raw log row, which becomes `$4` in the awk pass after the
  local-hour/epoch columns are pasted on (mirroring how `drive` is `$4` today).
  Only the printed column header is the letter. `DRIVE_LIST` passed into awk
  becomes the serial list; a parallel label list (or a map) supplies the display
  header.

Example output:

```
Hour-of-day activity (% of samples with I/O):

  legend: sda=WD-WCC4E1, sdb=WD-WCC4E2, sdc=ZA1-9KLM, sdd=ZA1-9KLN

        sda  sdb  sdc  sdd
  00      0    0    0    0
  01     12    0    0    0
  ...
```

## Log format and migration

The CSV header changes:

```
timestamp,serial,read_bytes,write_bytes,power_state
```

`EXPECTED_HEADER` is updated in both scripts. The existing header-mismatch guard
then automatically rejects any old letter-keyed log and tells the operator to
rotate it (`rm ~/.drive-usage.log`) — which is correct, since old letter rows
must not blend with new serial rows. The state file has no header guard but
self-heals as described above; the operator may also `rm` it but is not required
to.

## Documentation updates

- `README.md`: the `sda`–`sdd` sampler description, the rotation note, and the
  `~/.drive-usage.log` example header.
- `docs/superpowers/specs/2026-04-27-drive-usage-monitoring-design.md` and the
  matching plan: log-format and identity wording where they reference the
  `drive` column or `sda`-style keys.

## Testing

- `bash -n` and `shellcheck` both scripts (the existing
  `# shellcheck disable=SC2086` on the `DISK_DEVICES` loop stays).
- Sampler: run once (on a box or with a mocked resolver/`diskstats`), confirm log
  rows and state lines are serial-keyed.
- Report: feed a synthetic serial-keyed log that includes one serial with **no**
  current letter; confirm the legend, current-letter headers, and the
  absent-drive bare-serial fallback all render. Confirm an old letter-keyed log
  is rejected by the header guard.

## Decisions made without asking (reversible)

- WWN → `kname-<kname>` fallback chain for serial-less drives.
- The report shows since-replaced disks (serials in the log with no current
  letter) rather than hiding them.
