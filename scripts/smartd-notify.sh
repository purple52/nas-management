#!/bin/bash
source /etc/nas-management.conf
echo "$(date): SMART error on $SMARTD_DEVICE: $SMARTD_MESSAGE" >> "$ALERT_FILE"