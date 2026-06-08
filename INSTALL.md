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

## 1. Dependency

`hdparm` is already required by the repo; `sg3-utils` provides `sg_start` for the
USB backup drive (its enclosure ignores ATA standby, so SCSI STOP UNIT is the only
way to spin it down).

```bash
sudo apt install sg3-utils
```

## 2. Deploy the scripts

```bash
sudo cp scripts/backup-run scripts/backup-unmount scripts/disk-check /usr/local/bin/
sudo chmod +x /usr/local/bin/backup-run /usr/local/bin/backup-unmount /usr/local/bin/disk-check
```

## 3. Data-drive spindown — persistent udev rule (`sda`–`sdd`)

Generate the rule from the live drive→serial mapping so it survives `sdX`
reordering across reboots. Confirm `hdparm`'s path first:

```bash
command -v hdparm   # expect /usr/sbin/hdparm; adjust the RUN path below if different
{
  echo '# NAS data-drive spindown -- hdparm -S 241 (30 min). Managed by nas-management.'
  for d in /dev/sd[a-d]; do
    serial=$(udevadm info --query=property --name="$d" | sed -n 's/^ID_SERIAL_SHORT=//p')
    [ -n "$serial" ] && printf 'ACTION=="add", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ENV{ID_SERIAL_SHORT}=="%s", RUN+="/usr/sbin/hdparm -S 241 /dev/%%k"\n' "$serial"
  done
} | sudo tee /etc/udev/rules.d/99-nas-spindown.rules
```

`-S 241` = 30-minute standby timeout. `sde` (root) and `sdf` (backup) are
deliberately excluded — never spin down root, and `sdf` is handled in step 4.

Apply without rebooting and verify all four drives matched:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger --action=add --subsystem-match=block
for d in sda sdb sdc sdd; do
  echo -n "$d: "; sudo udevadm test /sys/block/$d 2>&1 | grep -o 'hdparm -S 241 /dev/sd.' || echo "NO MATCH"
done
```

Each line should print `hdparm -S 241 /dev/sdX`. Any `NO MATCH` means that drive's
serial didn't make it in — re-run the generator. (`config/99-nas-spindown.rules`
in the repo is a placeholder template; the generator above is what produces the
real file.)

## 4. USB backup drive — `smartd` carve-out

The backup drive parks via `sg_start` (deployed in step 2), but `smartd`'s 30-min
poll would wake it: this enclosure can't report power state, so smartd's
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

## 5. Verify

```bash
# Park the backup drive now — expect "Backup drive spun down":
sudo backup-unmount

# Logins no longer wake the array; parked drives report standby:
disk-check                              # data drives show "standby (not woken)"
```

Then leave `sdf` entirely alone for 10+ minutes (no `smartctl`/`hdparm`/`ls` on it)
and listen — it should stay spun down and quiet. PWL clicking stops while parked.

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
