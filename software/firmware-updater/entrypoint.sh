#!/bin/bash
# CybICS Firmware Update Service – container entrypoint
#
# 1. Verifies that the shared MAC secret exists.
# 2. Starts the Python update daemon.

set -e

SECRET_FILE="/opt/cybics/secrets/secret.bin"

if [ ! -f "$SECRET_FILE" ]; then
    echo "[entrypoint] ERROR: MAC secret not found at $SECRET_FILE" >&2
    echo "[entrypoint] ERROR: Provision the secret from update-server via shared volume." >&2
    exit 1
fi

mkdir -p /opt/cybics/firmware /opt/cybics/logs

exec python3 /opt/cybics/update-service/update_daemon.py
