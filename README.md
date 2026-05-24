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

Edit `/etc/nas-management.conf` — set `NAS_USER` to your username and adjust any paths or thresholds.

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
sudo apt install smartmontools mdadm rsnapshot cryptsetup acl hdparm
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
  smartd.conf            SMART monitoring configuration

systemd/
  mdcheck_start-notify.conf      Scrub notification drop-in
  mdcheck_continue-notify.conf   Scrub notification drop-in
```