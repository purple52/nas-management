# NAS Monitoring & Backup Scripts

Scripts for monitoring disk health and managing encrypted incremental backups on a Linux NAS.

## Disk Monitoring

### Login Status

On SSH login, `disk-check` and `backup-check` run automatically (add to `.zshrc`):

```
=== Disk Status ===

RAID Arrays:
  /dev/md0: healthy [UU]
  /dev/md1: healthy [UU]

Storage:
  /mnt/bucket-md0: 6.4T/7.2T (94%) ⚠ LOW SPACE
  /mnt/bucket-md1: 713G/3.6T (20%)

Disk alerts: none

=== Backup Status ===

Last activity: 2026-02-24 02:00:01 OK daily completed
```

### How It Works

All disk events are logged to `~/.disk-alerts`:

- **smartd** calls `smartd-notify.sh` on SMART errors (reallocated sectors, temperature warnings, self-test failures)
- **mdadm** calls `mdadm-notify.sh` on array events (degraded, rebuild, failure)
- **mdcheck** calls `mdcheck-notify.sh` after monthly RAID scrubs, logging mismatch counts

`disk-check` reads `/proc/mdstat` for RAID status, `df` for space, and `~/.disk-alerts` for any warnings. With sudo, it also reports drive temperatures via `smartctl`.

### Scrub Notifications

Systemd drop-ins hook into the existing `mdcheck_start` and `mdcheck_continue` services to log scrub results:

```ini
# /etc/systemd/system/mdcheck_start.service.d/notify.conf
# /etc/systemd/system/mdcheck_continue.service.d/notify.conf
[Service]
ExecStartPost=/usr/local/bin/mdcheck-notify.sh
```

### Commands

| Command | Description |
|---------|-------------|
| `disk-check` | RAID status, storage usage, alerts |
| `sudo disk-check` | Same, plus drive temperatures |
| `disk-clear-alerts` | Clear the alert log |

## Drive Usage Monitoring

A 15-minute sampler that captures per-drive I/O activity and power state over time. Used in two phases: first to inform an `hdparm` spindown decision, then — once a timeout is configured — to verify it's engaging and tune it.

### How It Works

Every 15 minutes, cron runs `drive-usage-sample`. The script reads cumulative read/write counters for `sda`–`sdd` from `/proc/diskstats`, diffs them against the previous run's values stored in `~/.drive-usage-state`, queries each drive's power state via `hdparm -C` (which does not spin the drive up, unlike `smartctl`), and appends one CSV row per drive to `~/.drive-usage.log`:

```
timestamp,drive,read_bytes,write_bytes,power_state
2026-04-27T14:15:00,sda,0,0,standby
2026-04-27T14:15:00,sdb,131072,8192,active/idle
...
```

Timestamps are UTC (avoids DST shifts mid-collection); the report converts to localtime per-row when bucketing by hour. No `sysstat`/`iostat` dependency — `/proc/diskstats` exposes the same counters.

If the log format changes (e.g. a new column is added), both scripts refuse to run against the old log and tell you to rotate it with `rm ~/.drive-usage.log`. The state file is unaffected and can stay in place.

### Commands

| Command | Description |
|---------|-------------|
| `drive-usage-report` | Activity heatmap, idle-run summary, standby heatmap, spin-up counts |
| `drive-usage-sample` | 15-min sampler — invoked by cron, not run manually |

### Reading the Report

Four views:
- **Hour-of-day I/O heatmap:** % of samples with any I/O, by hour (localtime). Reveals quiet windows.
- **Idle-run summary:** longest no-I/O run per drive plus counts of runs >=1h, >=2h, >=4h. Tells you whether a candidate `hdparm` timeout would actually catch idle time.
- **Hour-of-day standby heatmap:** % of samples in `standby`/`sleeping`, by hour. After enabling spindown, this should be near 100 during the hours the I/O heatmap is 0. Discrepancies mean the timeout is too long or something is touching the drive.
- **Spin-up event counts:** total `standby → active/idle` transitions per drive, plus a per-day rate. A handful per day is healthy; double digits suggests the timeout is too short for the workload.

If a drive shows many >=2h idle runs, a spindown of ~30 min would catch real idle time. If it never gets a >=1h run, spindown isn't worthwhile for that drive.

## Drive Spindown

Once the usage report confirms long idle runs and a low spin-up rate, an `hdparm` standby timeout is made persistent via a udev rule (`config/99-nas-spindown.rules` → `/etc/udev/rules.d/`).

The rule is keyed on each disk's serial (`ID_SERIAL_SHORT`), not its `sdX` name — kernel names can reorder across reboots, serials don't. It fires on `add`, so it applies on both boot and hotplug. The configured timeout is `-S 241` (30 minutes; values 241–251 encode `(N−240) × 30 min`).

Only the RAID member disks are included. The root drive and the removable USB backup drive are deliberately excluded — root has constant background I/O that would thrash a parked disk, and the backup drive is unlocked on demand by `backup-run`. The rule is generated from `/proc/mdstat` (RAID membership), not a device-letter glob, so a kernel letter reorder can't make it pick up root or miss an array drive.

The shipped rule file holds placeholder serials and must not be installed verbatim; the install step below generates the real file from the live drive→serial mapping. After enabling, the standby heatmap and spin-up counts in `drive-usage-report` confirm it's engaging without thrashing.

## Backup System

Encrypted incremental backups to a removable USB drive using rsnapshot (rsync + hard links).

### How rsnapshot Works

Each snapshot looks like a full copy, but unchanged files are hard-linked — only modified files consume additional space. Snapshots are rotated automatically:

- **daily**: keeps 7 snapshots
- **weekly**: promoted from oldest daily, keeps 4
- **monthly**: promoted from oldest weekly, keeps 6

Rotation must run in order: monthly → weekly → daily. The `backup-run` script handles this automatically based on when each level last ran.

### Encryption

The backup drive uses LUKS. A keyfile allows automated unlocking without a passphrase prompt:

```bash
# One-time setup
sudo dd if=/dev/urandom of=/etc/backup-luks.key bs=4096 count=1
sudo chmod 600 /etc/backup-luks.key
sudo cryptsetup luksAddKey /dev/sdX1 /etc/backup-luks.key
```

The keyfile is root-readable only. Since the NAS stores data unencrypted, the keyfile doesn't weaken security — the encryption protects the drive when stored offsite.

### Automation

A cron job runs `backup-run` at 2am daily:

```
# /etc/cron.d/backup
0 2 * * * root /usr/local/bin/backup-run
```

If the drive is plugged in, it unlocks, mounts, runs whichever backup levels are due, unmounts, and locks. If the drive isn't connected, it exits silently.

### Drive Spindown

The backup drive is left connected 24/7 but only used at 2am. Its WD Elements enclosure ignores ATA standby (`hdparm -S`/`-C` return `unknown`), so spindown is handled two ways: the enclosure's own SCSI **STANDBY_Z timer** (set via `sdparm` to 15 min — see INSTALL.md) parks the drive after any idle period and re-parks it after stray wakes, and `backup-run`/`backup-unmount` additionally issue a SCSI **STOP UNIT** (`sg_start --stop`) once unmounted and locked to park it immediately rather than waiting out the timer. The `sg_start` step is best-effort and never affects the backup's exit status.

Because this enclosure can't report power state, `smartd`'s `-n standby` guard can't tell the drive is parked, so a normal 30-min poll would wake it and undo the spindown. For that reason `smartd.conf` does **not** use `DEVICESCAN` — it lists the internal SATA drives (root + array members) explicitly by `/dev/disk/by-id/`, selected by transport so the USB backup drive is left out regardless of its device letter. `backup-run` instead checks `sdf`'s SMART health and temperature while it's mounted and spun up, appending any problem to the disk alert file.

Note the periodic clicking from this (helium WD/HGST) drive is normal **Preventive Wear Leveling**, not a fault — confirmed by clean SMART (0 reallocated/pending/CRC).

### Commands

| Command | Description |
|---------|-------------|
| `sudo backup-run` | Run backup — determines what's needed automatically |
| `sudo backup-mount` | Unlock, mount, and show backup drive summary |
| `sudo backup-unmount` | Unmount and lock (safe to unplug) |
| `backup-check` | Show backup status and last activity |

## Installation

### Config → `/etc/`

```bash
sudo cp config/nas-management.conf /etc/nas-management.conf
```

Edit `/etc/nas-management.conf` — set `NAS_USER` to your username and adjust paths or thresholds. Set `BACKUP_DEVICE`/`BACKUP_PARTITION` to stable `/dev/disk/by-id/` paths (**not** `/dev/sdX` — kernel letters reorder across reboots, which would point the backup at the wrong drive). `DISK_DEVICES` self-resolves to the RAID member disks from `/proc/mdstat`, so it needs no editing and follows the array through any letter shuffle. See [INSTALL.md](INSTALL.md) for the device-identifier setup and the drive-spindown runbook.

### Scripts → `/usr/local/bin/`

```bash
sudo cp scripts/* /usr/local/bin/
sudo chmod +x /usr/local/bin/backup-* /usr/local/bin/disk-* /usr/local/bin/drive-usage-* /usr/local/bin/smartd-notify.sh /usr/local/bin/mdadm-notify.sh /usr/local/bin/mdcheck-notify.sh
```

### Cron

```bash
sudo cp config/cron-backup /etc/cron.d/backup
sudo chmod 644 /etc/cron.d/backup
sudo cp config/cron-drive-usage /etc/cron.d/drive-usage
sudo chmod 644 /etc/cron.d/drive-usage
```

### Systemd Drop-ins

```bash
sudo mkdir -p /etc/systemd/system/mdcheck_start.service.d
sudo mkdir -p /etc/systemd/system/mdcheck_continue.service.d
sudo cp systemd/mdcheck_start-notify.conf /etc/systemd/system/mdcheck_start.service.d/notify.conf
sudo cp systemd/mdcheck_continue-notify.conf /etc/systemd/system/mdcheck_continue.service.d/notify.conf
sudo systemctl daemon-reload
```

### udev Rules (drive spindown)

`config/99-nas-spindown.rules` is a template with placeholder serials — don't copy it verbatim. The real rule is generated **on the box** from the RAID member disks (not a device-letter glob), keyed on each disk's `ID_SERIAL_SHORT` so it follows the hardware through any `sdX` reorder. `-S 241` is a 30-minute standby timeout; root and the USB backup drive are excluded by construction (they aren't RAID members).

See **[INSTALL.md](INSTALL.md) § 3** for the generator and verification commands. To check power state afterwards, query each RAID member by its current letter:

```bash
awk '/^md[0-9]/{for(i=1;i<=NF;i++) if($i ~ /^sd[a-z]+[0-9]*\[/){d=$i; sub(/\[.*/,"",d); sub(/[0-9]+$/,"",d); print d}}' /proc/mdstat | sort -u | while read -r d; do
  echo -n "$d: "; sudo hdparm -C "/dev/$d" | sed -n 's/.*drive state is: //p'
done
```

After a day, re-run `drive-usage-report` to confirm the standby heatmap climbs in idle hours and spin-up counts stay low.

### Login Status

Add to `~/.zshrc` (or `~/.bashrc`):

```bash
disk-check
backup-check
```

### Configuration

All scripts read from `/etc/nas-management.conf`. Edit that single file to set your username, device paths, mount points, and thresholds.

Additional per-file config:

- `config/rsnapshot.conf`: update `snapshot_root` and `backup` paths
- `config/smartd.conf`: update notification script path

### Dependencies

```bash
sudo apt install smartmontools mdadm rsnapshot cryptsetup acl hdparm sg3-utils sdparm
```

## File Inventory

```
scripts/
  backup-run             Main backup script (unlock, mount, rsnapshot, unmount)
  backup-check           Display backup status (for login)
  backup-mount           Mount backup drive and show summary
  backup-unmount         Safely unmount and lock backup drive
  disk-check             Display disk/RAID/storage status (for login)
  disk-clear-alerts      Clear the disk alert log
  drive-usage-sample     15-min /proc/diskstats sampler (cron)
  drive-usage-report     Hour-of-day and idle-run report
  smartd-notify.sh       Called by smartd on SMART errors
  mdadm-notify.sh        Called by mdadm on array events
  mdcheck-notify.sh      Called after RAID scrub completion

config/
  nas-management.conf    Shared configuration (install to /etc/)
  rsnapshot.conf         Backup configuration
  cron-backup            Cron job for nightly backups
  cron-drive-usage       Cron job for 15-min drive sampling
  99-nas-spindown.rules  udev spindown rule template (install to /etc/udev/rules.d/)
  smartd.conf            SMART monitoring configuration

systemd/
  mdcheck_start-notify.conf      Scrub notification drop-in
  mdcheck_continue-notify.conf   Scrub notification drop-in
```