#!/usr/bin/env bash
set -euo pipefail

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
APP_PORT="${APP_PORT:-8000}"

# Create group/user if needed
if ! getent group appgroup >/dev/null 2>&1; then
  groupadd -g "$PGID" appgroup >/dev/null 2>&1 || true
fi

if ! id appuser >/dev/null 2>&1; then
  useradd -m -u "$PUID" -g "$PGID" -s /usr/sbin/nologin appuser >/dev/null 2>&1 || true
fi

# Ensure ownership of app dir (idempotent)
chown -R "$PUID:$PGID" /app >/dev/null 2>&1 || true

# Secrets: prefer file, then env
if [[ -z "${INFLUX_PASS:-}" && -n "${INFLUX_PASS_FILE:-}" && -f "${INFLUX_PASS_FILE:-}" ]]; then
  # Read as root, export into env for the app process
  INFLUX_PASS="$(cat "${INFLUX_PASS_FILE}")"
  export INFLUX_PASS
fi

exec gosu "$PUID:$PGID" uvicorn app:APP --host 0.0.0.0 --port "$APP_PORT"
