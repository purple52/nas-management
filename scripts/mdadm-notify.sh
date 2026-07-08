#!/bin/bash
source /etc/nas-management.conf

msg="mdadm event '$1' on $2"

# Tag sync events with the actual md action so a routine scrub (check) is
# distinguishable from a real disk rebuild (recovery). mdadm reports both as
# 'RebuildStarted'. Skip when idle so non-sync events stay unadorned.
action_file="/sys/block/$(basename "$2")/md/sync_action"
if [ -r "$action_file" ]; then
    action=$(cat "$action_file")
    [ "$action" != idle ] && msg="$msg [$action]"
fi

echo "$(date): $msg" >> "$ALERT_FILE"