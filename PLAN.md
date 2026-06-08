# Plan: NAS Management Bug Fixes + Config Cleanup

## Context

The system has working scripts but several bugs and a maintenance problem: every configurable value (device paths, mount points, usernames, thresholds) is hardcoded independently in each script. The three notify scripts use a `/home/YOURUSERNAME/` placeholder that needs manual replacement in 3 files. `backup-run` has a race-vulnerable lock and its trap doesn't clean up mounts. `backup-mount` doesn't check whether cryptsetup/mount succeeded before displaying summary data.

## Changes

### 1. Create shared config file `config/nas-management.conf`

All scripts will `source /etc/nas-management.conf` as their first action. This eliminates all duplication and the YOURUSERNAME placeholder problem.

```bash
# /etc/nas-management.conf
NAS_USER="YOURUSERNAME"
ALERT_FILE="/home/YOURUSERNAME/.disk-alerts"
BACKUP_STATUS_FILE="/home/YOURUSERNAME/.backup-status"

BACKUP_DEVICE="/dev/sdf"
BACKUP_PARTITION="/dev/sdf1"
MAPPER_NAME="backups"
MOUNT_POINT="/mnt/backups"
KEYFILE="/etc/backup-luks.key"

MONITORED_MOUNTS="/mnt/bucket-md0 /mnt/bucket-md1"
DISK_DEVICES="/dev/sd[a-d]"

SPACE_WARN_PCT=90
TEMP_WARN_C=50
BACKUP_STALE_DAYS=3
```

### 2. Fix `backup-run` — locking, trap, config

**Files:** `scripts/backup-run`

- **Source config**, remove local constant definitions (lines 3-6)
- **Replace PID lockfile** (lines 8-14) with `flock`:
  ```bash
  LOCKFILE="/var/run/backup-run.lock"
  exec 9>"$LOCKFILE"
  if ! flock -n 9; then
      echo "Backup already running"
      exit 0
  fi
  ```
  Eliminates TOCTOU race. Lock auto-releases on process exit (including SIGKILL).

- **Replace trap** with full cleanup:
  ```bash
  cleanup() {
      if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
          umount "$MOUNT_POINT" 2>/dev/null
      fi
      if [ -b /dev/mapper/"$MAPPER_NAME" ]; then
          cryptsetup close "$MAPPER_NAME" 2>/dev/null
      fi
  }
  trap cleanup EXIT
  ```

- **Remove explicit unmount/close** at bottom (lines 113-114); the trap handles this
- **Replace** hardcoded `/dev/sdf`, `/dev/sdf1` with `$BACKUP_DEVICE`, `$BACKUP_PARTITION`
- **Rename** `$LOG` → `$BACKUP_STATUS_FILE` in `log_msg`
- **Quote** `/dev/mapper/$MAPPER_NAME` → `/dev/mapper/"$MAPPER_NAME"` (lines 27, 38)

### 3. Fix `backup-mount` — error checking, config

**Files:** `scripts/backup-mount`

- **Source config**, remove local constants (lines 2-4)
- **Add error checking** on cryptsetup and mount:
  ```bash
  if ! cryptsetup open "$BACKUP_PARTITION" "$MAPPER_NAME" --key-file "$KEYFILE"; then
      echo "ERROR: Failed to unlock LUKS device"
      exit 1
  fi
  ...
  if ! mount /dev/mapper/"$MAPPER_NAME" "$MOUNT_POINT"; then
      echo "ERROR: Failed to mount filesystem"
      exit 1
  fi
  ```
- **Replace** hardcoded `/dev/sdf`, `/dev/sdf1` with config variables
- **Quote** `/dev/mapper/$MAPPER_NAME`

### 4. Fix `backup-unmount` — config, quoting

**Files:** `scripts/backup-unmount`

- **Source config**, remove local constants (lines 2-3)
- **Quote** `/dev/mapper/$MAPPER_NAME` (line 12)

### 5. Fix `backup-check` — config

**Files:** `scripts/backup-check`

- **Source config**, remove `STATUS_FILE` (line 3), use `$BACKUP_STATUS_FILE`
- **Replace** hardcoded 3-day threshold (line 30) with `$BACKUP_STALE_DAYS`

### 6. Fix `disk-check` — grep -P, config

**Files:** `scripts/disk-check`

- **Source config**, remove `ALERT_FILE` (line 2)
- **Change** `grep -qP` to `grep -qE` (line 20) — same semantics, no PCRE dependency
- **Replace** hardcoded mount paths (line 34) with `$MONITORED_MOUNTS`
- **Replace** hardcoded `/dev/sd[a-d]` (line 59) with `$DISK_DEVICES`
- **Replace** hardcoded 90 threshold (line 36) with `$SPACE_WARN_PCT`
- **Replace** hardcoded 50 threshold (line 64) with `$TEMP_WARN_C`

### 7. Fix remaining scripts — config

- **`disk-clear-alerts`**: Source config, remove `ALERT_FILE` (line 2)
- **`smartd-notify.sh`**: Source config, replace hardcoded path with `$ALERT_FILE`
- **`mdadm-notify.sh`**: Source config, replace hardcoded path with `$ALERT_FILE`
- **`mdcheck-notify.sh`**: Source config, remove local `ALERT_FILE` (line 2)

### 8. Update docs

**`README.md`**: Add config file install step before scripts section. Simplify the Configuration section — instead of listing 5+ per-file edits, point to the single config file. The only remaining per-file edit is `rsnapshot.conf` (backup paths) and `smartd.conf` (notification script path). Update file inventory.

**`CLAUDE.md`**: Note that config is centralized in `/etc/nas-management.conf`. Remove YOURUSERNAME placeholder note.

## Verification

After all changes:
1. `shellcheck scripts/*` — no errors (beyond existing SC2086 on intentionally unquoted `$MONITORED_MOUNTS`/`$DISK_DEVICES`)
2. Verify each script starts with `source /etc/nas-management.conf`
3. `grep -r 'YOURUSERNAME' scripts/` — zero results
4. `grep -r '/home/david' scripts/` — zero results
5. `grep -r 'grep -P' scripts/` — zero results
6. `grep -rn '/dev/mapper/$' scripts/` — zero results (all quoted)
7. Verify `backup-run` uses `flock` and has `cleanup` trap
8. Verify `backup-mount` exits on cryptsetup/mount failure