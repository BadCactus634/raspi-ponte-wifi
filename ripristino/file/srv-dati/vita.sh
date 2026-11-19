#!/bin/bash
# Battito del ponte WiFi verso il monitor push di Kuma (VPS), ogni 60 s.
source /srv/dati/stato/kuma_push.env
while true; do
    curl -s -m 20 -A "Mozilla/5.0 enjoybuds-ponte" -o /dev/null "$KUMA_PUSH_URL?status=up&msg=OK&ping=" || true
    sleep 60
done
