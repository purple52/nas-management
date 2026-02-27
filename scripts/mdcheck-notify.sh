#!/bin/bash
source /etc/nas-management.conf
for dev in /dev/md?*; do
    [ -e "$dev" ] || continue
    name=$(basename "$dev")
    sys=$(readlink -f /sys/dev/block/$(stat -c '%t:%T' "$dev" | sed 's/:/ /'))
    if [ -f "$sys/md/mismatch_cnt" ]; then
        cnt=$(cat "$sys/md/mismatch_cnt")
        if [ "$cnt" -gt 0 ]; then
            echo "$(date): SCRUB WARNING /dev/$name: $cnt mismatches found" >> "$ALERT_FILE"
        else
            echo "$(date): SCRUB OK /dev/$name: no mismatches" >> "$ALERT_FILE"
        fi
    fi
done