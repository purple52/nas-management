# Installation — Drive Spindown

Deployment runbook for the drive-spindown changes. Run these **on the NAS**.
Some steps generate machine-specific files (keyed on the actual drive serials),
which is why they can't simply be `cp`'d from the repo.

For the broader component overview see [README.md](README.md). What this runbook sets up:

| Piece | Effect |
|-------|--------|
| `disk-check` (`-n standby`) | SSH logins stop spinning up the parked array drives |
| udev rule (`sda`–`sdd`) | data drives spin down after 30 min idle, persists across reboot |
| `backup-run` / `backup-unmount` (`sg_start`) | USB backup drive (`sdf`) parks after each backup |
| `smartd.conf` (no `DEVICESCAN`) | smartd's 30-min poll no longer wakes the parked backup drive |

Device layout assumed here: `sda`–`sdd` data drives, `sde` root, `sdf` removable
USB backup drive. Adjust the globs if your layout differs.

## 1. Dependencies

`hdparm` is already required by the repo. For the USB backup drive (whose WD
Elements enclosure ignores ATA standby): `sdparm` configures the enclosure's own
SCSI standby timer (the actual spindown mechanism), and `sg3-utils` provides
`sg_start` to park it immediately at the end of a backup.

```bash
sudo apt install sg3-utils sdparm
```

## 2. Deploy the scripts and config

```bash
sudo cp scripts/backup-run scripts/backup-unmount scripts/disk-check /usr/local/bin/
sudo chmod +x /usr/local/bin/backup-run /usr/local/bin/backup-unmount /usr/local/bin/disk-check
sudo cp config/nas-management.conf /etc/nas-management.conf
```

Then edit `/etc/nas-management.conf` and set the backup drive to **stable
`/dev/disk/by-id` paths** (never `/dev/sdX` — letters reorder). Find yours:

```bash
udevadm info -q symlink -n /dev/sdf | tr ' ' '\n' | grep by-id   # use your backup drive's current letter
```

Set `BACKUP_DEVICE` to the whole-disk `usb-...` symlink and `BACKUP_PARTITION` to
the same with `-part1`. `DISK_DEVICES` needs no editing — it derives the array
members from `/proc/mdstat` at runtime. Confirm both resolve correctly:

```bash
source /etc/nas-management.conf
echo "backup : $BACKUP_DEVICE"; [ -b "$BACKUP_DEVICE" ] && echo "  -> OK block device"
echo "data   : $DISK_DEVICES"           # should list your RAID member disks
```

## 3. Data-drive spindown — persistent udev rule (RAID members)

Generate the rule from the **actual RAID member disks** (not an `sd[a-d]` glob —
device letters reorder across reboots, and a letter glob will silently pick up the
root drive and miss an array drive). The rule is serial-keyed, so once generated it
follows the physical drives regardless of letters. Confirm `hdparm`'s path first:

These snippets use a `while read` pipe (no `mapfile`) so they work under both bash
and zsh — the NAS's interactive shell is zsh, where `mapfile` doesn't exist.

```bash
command -v hdparm   # expect /usr/sbin/hdparm; adjust the RUN path below if different

# Sanity-check the member list before writing anything:
awk '/^md[0-9]/{for(i=1;i<=NF;i++) if($i ~ /^sd[a-z]+[0-9]*\[/){d=$i; sub(/\[.*/,"",d); sub(/[0-9]+$/,"",d); print d}}' /proc/mdstat | sort -u

{
  echo '# NAS data-drive spindown -- hdparm -S 241 (30 min). Generated from RAID members.'
  awk '/^md[0-9]/{for(i=1;i<=NF;i++) if($i ~ /^sd[a-z]+[0-9]*\[/){d=$i; sub(/\[.*/,"",d); sub(/[0-9]+$/,"",d); print d}}' /proc/mdstat | sort -u | while read -r d; do
    serial=$(udevadm info -q property -n "/dev/$d" | sed -n 's/^ID_SERIAL_SHORT=//p')
    [ -n "$serial" ] && printf 'ACTION=="add", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ENV{ID_SERIAL_SHORT}=="%s", RUN+="/usr/sbin/hdparm -S 241 /dev/%%k"\n' "$serial"
  done
} | sudo tee /etc/udev/rules.d/99-nas-spindown.rules
```

`-S 241` = 30-minute standby timeout. The root drive and the USB backup drive are
excluded by construction (they aren't RAID members); the backup drive is handled in
step 4.

Confirm the rules were written, apply, and verify each array disk matched:

```bash
grep -c '^ACTION' /etc/udev/rules.d/99-nas-spindown.rules   # expect one line per array disk
sudo udevadm control --reload-rules
sudo udevadm trigger --action=add --subsystem-match=block
awk '/^md[0-9]/{for(i=1;i<=NF;i++) if($i ~ /^sd[a-z]+[0-9]*\[/){d=$i; sub(/\[.*/,"",d); sub(/[0-9]+$/,"",d); print d}}' /proc/mdstat | sort -u | while read -r d; do
  echo -n "$d: "; sudo udevadm test /sys/block/$d 2>&1 | grep -o "hdparm -S 241 /dev/$d" || echo "NO MATCH"
done
```

Each line should print `hdparm -S 241 /dev/sdX`. (`config/99-nas-spindown.rules` in
the repo is a placeholder template; the generator above produces the real file.)

## 4. USB backup drive — enclosure standby timer (`sdparm`)

The WD Elements enclosure ignores ATA standby (`hdparm`), and a one-shot SCSI
`STOP UNIT` doesn't *hold* (the drive spins back up on the next access and nothing
re-parks it). What works is the enclosure's own **STANDBY_Z timer**, which re-parks
the drive after each idle period. It ships enabled with a 30-min timer; set a
shorter, persistent value:

```bash
sudo sdparm --page=po /dev/sdf                              # inspect: STANDBY_Z 1, SZCT in 100ms units
sudo sdparm --page=po --set=SZCT=9000 --save /dev/sdf       # 15-min timer, persists across power-cycle
sudo sdparm --page=po /dev/sdf | grep -E 'STANDBY_Z|SZCT'   # confirm STANDBY_Z 1, SZCT 9000
```

`SZCT` is in 100 ms units (9000 = 15 min). The 2am `backup-run` also issues
`sg_start --stop` at the end to park `sdf` immediately rather than waiting out the
timer; the timer's role is to re-park it after any random daytime wake.

Verify it actually parks: leave `sdf` **completely alone** for ~20 min (no
`smartctl`/`hdparm`/`sdparm`/`ls`), then check the enclosure — quiet, LED flashing =
parked. A `smartctl -A /dev/sdf` temperature read should show it has dropped well
below the ~44 °C spinning-idle figure (the read itself wakes it again).

## 5. USB backup drive — `smartd` carve-out

The drive now parks itself (step 4), but `smartd`'s 30-min poll would be one of the
wakes that prevents it: this enclosure can't report power state, so smartd's
`-n standby` guard never detects standby. So `sdf` must come out of smartd.

Generate explicit device lines for the **internal** drives only (`sda`–`sde`):

```bash
OPTS='-a -o on -S on -n standby,q -s (S/../.././02|L/../../6/03) -W 4,50,55 -m root -M exec /usr/local/bin/smartd-notify.sh'
for d in /dev/sd[a-e]; do
  id=$(udevadm info -q symlink -n "$d" | tr ' ' '\n' | grep -m1 '^disk/by-id/ata-') \
    || id=$(udevadm info -q symlink -n "$d" | tr ' ' '\n' | grep -m1 '^disk/by-id/wwn-')
  [ -n "$id" ] && echo "/dev/$id $OPTS"
done
```

Edit `/etc/smartd.conf`: **comment out the `DEVICESCAN` line** and paste the five
generated lines in its place. Then reload and verify:

```bash
sudo systemctl restart smartmontools    # or: sudo systemctl restart smartd
sudo systemctl status smartmontools     # active, "Next check of 5 devices"
journalctl -u smartmontools -b | grep -iE 'Device:|Monitoring'
```

Confirm it lists **five** devices and **`sdf` (the WD180EDGZ) is not among them**.

## 6. Verify

```bash
# Park the backup drive now — expect "Backup drive spun down":
sudo backup-unmount

# Logins no longer wake the array; parked drives report standby:
disk-check                              # data drives show "standby (not woken)"
```

Then leave `sdf` entirely alone for ~20 minutes (no `smartctl`/`hdparm`/`ls` on it).
Confirmed-good signs: the enclosure goes quiet, its LED flashes (standby), and a
one-off `smartctl -A /dev/sdf` temperature read shows it dropped from ~44 °C
(spinning) to the low-20s °C (parked). PWL clicking only happens while spinning, so
it stops too.

Over the next day, `drive-usage-report` should show the standby heatmap climbing in
idle hours and spin-up counts staying low. The 2am `backup-run` spins `sdf` up,
backs up, health-checks it (SMART + temperature, since smartd no longer does), then
parks it again.

## Notes

- **The clicking from `sdf` is normal.** The WD180EDGZ is a helium drive; the
  periodic click is Preventive Wear Leveling (PWL), confirmed harmless by clean
  SMART (0 reallocated / pending / CRC). It only happens while spinning, so
  spindown silences it.
- **Reboot test for the data drives:** after a reboot, re-run the `udevadm test`
  loop from step 3 to confirm the rules still match the serials.
