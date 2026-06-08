# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Bash scripts for monitoring disk health and managing encrypted incremental backups on a Linux NAS. Two main systems: **disk monitoring** (SMART + RAID event handlers with status display) and **backup management** (LUKS-encrypted rsnapshot incremental backups to removable USB drive).

## Architecture

### Disk Monitoring (event-driven)
- `smartd` → `smartd-notify.sh` → appends to `~/.disk-alerts`
- `mdadm` → `mdadm-notify.sh` → appends to `~/.disk-alerts`
- `mdcheck` systemd drop-ins → `mdcheck-notify.sh` → appends to `~/.disk-alerts`
- `disk-check` reads `/proc/mdstat`, `df`, and `~/.disk-alerts` to display status

### Backup System (cron-triggered)
- Cron (2am daily) → `backup-run` → LUKS unlock → mount → rsnapshot (monthly → weekly → daily as needed) → unmount → LUKS lock
- `backup-run` determines which snapshot levels are due by checking timestamps on the backup drive
- Uses `flock` for locking with EXIT trap that cleans up mounts and LUKS
- Exits silently if backup drive not connected

### Configuration
- All scripts source `/etc/nas-management.conf` (repo source: `config/nas-management.conf`)
- Key paths, device names, thresholds, and username are centralized there
- Only `rsnapshot.conf` and `smartd.conf` have separate per-file config

## Development Notes

- **No build system or test suite** — all scripts are plain bash, manually tested
- Scripts install to `/usr/local/bin/` via `sudo cp`
- Config files go to `/etc/cron.d/`, `/etc/systemd/system/*/`, etc.
- rsnapshot.conf uses **tabs** as delimiters (not spaces) — rsnapshot will reject spaces
- rsnapshot rotation order matters: monthly → weekly → daily (never reverse)
- System dependencies: `smartmontools mdadm rsnapshot cryptsetup acl`