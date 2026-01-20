#!/usr/bin/env bash
set -euo pipefail

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
APP_PORT="${APP_PORT:-8000}"

# Resolve any VAR_FILE into VAR (if VAR is empty/unset)
resolve_env_files() {
  for env_k in $(env | awk -F= '/_FILE=/{print $1}'); do
    base="${env_k%_FILE}"
    file_path="$(printenv "$env_k" || true)"

    # Only populate base var if it's empty/unset
    if [[ -z "${!base:-}" && -n "${file_path:-}" ]]; then
      if [[ -f "$file_path" ]]; then
        export "$base"="$(cat "$file_path")"
      else
        echo "WARN: ${env_k} points to missing file: ${file_path}" >&2
      fi
    fi
  done
}

resolve_env_files

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
