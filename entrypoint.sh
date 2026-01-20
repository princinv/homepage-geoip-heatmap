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

# Ensure a group exists with PGID
if ! getent group "$PGID" >/dev/null 2>&1; then
  groupadd -g "$PGID" appgroup
fi

# Ensure a user exists with PUID
if ! getent passwd "$PUID" >/dev/null 2>&1; then
  useradd -m -u "$PUID" -g "$PGID" -s /usr/sbin/nologin appuser
fi

# Ensure ownership of app dir (idempotent)
chown -R "$PUID:$PGID" /app >/dev/null 2>&1 || true

exec gosu "$PUID:$PGID" uvicorn app:APP --host 0.0.0.0 --port "$APP_PORT"
