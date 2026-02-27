#!/bin/bash
source /etc/nas-management.conf
echo "$(date): mdadm event '$1' on $2" >> "$ALERT_FILE"