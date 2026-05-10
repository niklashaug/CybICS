#!/bin/sh
set -e

SECRET_FILE="${SECRET_PATH:-/opt/cybics/secrets/secret.bin}"
SECRET_DIR="$(dirname "$SECRET_FILE")"
FIRMWARE_FILE="${FIRMWARE_PATH:-/opt/cybics/update-server/firmware/current.bin}"
FIRMWARE_DIR="$(dirname "$FIRMWARE_FILE")"

mkdir -p "$SECRET_DIR" "$FIRMWARE_DIR"

if [ ! -f "$SECRET_FILE" ]; then
    echo "[entrypoint] Generating 16-byte MAC secret..."
    dd if=/dev/urandom bs=16 count=1 of="$SECRET_FILE" 2>/dev/null
    chmod 600 "$SECRET_FILE"
    echo "[entrypoint] MAC secret written to $SECRET_FILE"
fi

if [ "$#" -eq 0 ]; then
    set -- uvicorn app:create_app --factory --host 0.0.0.0 --port 6689
fi

exec "$@"
