#!/usr/bin/env bash

set -u

ASSETS_MIRROR_ROOT="${ASSETS_MIRROR_ROOT:-/srv/docker/repos/assets}"
MODE="check"
DELETE_EXTRAS="false"
ALLOW_EXTRAS="false"
VERBOSE="false"

usage() {
  cat <<'USAGE'
Usage:
  .scripts/sync-assets-mirror.sh --check [--allow-extra] [--verbose]
  .scripts/sync-assets-mirror.sh --sync [--delete] [--verbose]

Central assets are authoritative:
  /srv/docker/repos/assets/<repo-name>/...

Project assets are the synced mirror:
  <repo>/assets/...

Default repo-name resolution:
  1. .assets-mirror-name file
  2. origin remote basename
  3. repository directory basename
USAGE
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --check)
      MODE="check"
      ;;
    --sync)
      MODE="sync"
      ;;
    --delete)
      DELETE_EXTRAS="true"
      ;;
    --allow-extra|--allow-extras)
      ALLOW_EXTRAS="true"
      ;;
    --strict)
      ALLOW_EXTRAS="false"
      ;;
    --verbose)
      VERBOSE="true"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

resolve_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

resolve_mirror_name() {
  local resolved_repo_root
  local remote_url
  local remote_name
  local dir_name

  resolved_repo_root="$(resolve_repo_root)"

  if [[ -f "$resolved_repo_root/.assets-mirror-name" ]]; then
    sed -n '1p' "$resolved_repo_root/.assets-mirror-name" | tr -d '[:space:]'
    return 0
  fi

  remote_url="$(git -C "$resolved_repo_root" remote get-url origin 2>/dev/null || true)"
  if [[ -n "$remote_url" ]]; then
    remote_name="$(basename "$remote_url")"
    remote_name="${remote_name%.git}"
    if [[ -n "$remote_name" ]]; then
      printf '%s\n' "$remote_name"
      return 0
    fi
  fi

  dir_name="$(basename "$resolved_repo_root")"
  printf '%s\n' "$dir_name"
}

sha_file() {
  sha256sum "$1" | awk '{print $1}'
}

repo_root="$(resolve_repo_root)"
mirror_name="$(resolve_mirror_name)"
central_dir="$ASSETS_MIRROR_ROOT/$mirror_name"
local_dir="$repo_root/assets"

if [[ ! -d "$ASSETS_MIRROR_ROOT" ]]; then
  echo "SKIP: central assets root missing: $ASSETS_MIRROR_ROOT"
  exit 0
fi

if [[ ! -d "$central_dir" ]]; then
  echo "SKIP: no central assets folder for $mirror_name"
  exit 0
fi

central_count="$(
  find "$central_dir" -type f ! -name '.gitkeep' | wc -l
)"

if [[ "$central_count" -eq 0 ]]; then
  echo "SKIP: central assets folder is empty for $mirror_name"
  exit 0
fi

mkdir -p "$local_dir"

if [[ "$MODE" == "sync" ]]; then
  rsync_args=(-a --exclude '.gitkeep')

  if [[ "$DELETE_EXTRAS" == "true" ]]; then
    rsync_args+=(--delete)
  fi

  rsync "${rsync_args[@]}" "$central_dir/" "$local_dir/"

  echo "Synced assets for $mirror_name:"
  echo "  from: $central_dir/"
  echo "  to:   $local_dir/"

  if [[ "$DELETE_EXTRAS" != "true" ]]; then
    echo "Note: local extra files were not deleted."
  fi
fi

missing=0
mismatch=0
extra=0

while IFS= read -r -d '' central_file; do
  rel="${central_file#"$central_dir/"}"
  local_file="$local_dir/$rel"

  if [[ ! -f "$local_file" ]]; then
    echo "MISSING: assets/$rel"
    missing=$((missing + 1))
    continue
  fi

  central_sha="$(sha_file "$central_file")"
  local_sha="$(sha_file "$local_file")"

  if [[ "$central_sha" != "$local_sha" ]]; then
    echo "MISMATCH: assets/$rel"
    mismatch=$((mismatch + 1))
    continue
  fi

  if [[ "$VERBOSE" == "true" ]]; then
    echo "OK: assets/$rel"
  fi
done < <(find "$central_dir" -type f ! -name '.gitkeep' -print0 | sort -z)

while IFS= read -r -d '' local_file; do
  rel="${local_file#"$local_dir/"}"
  central_file="$central_dir/$rel"

  if [[ ! -f "$central_file" ]]; then
    echo "EXTRA: assets/$rel"
    extra=$((extra + 1))
  fi
done < <(find "$local_dir" -type f ! -name '.gitkeep' -print0 | sort -z)

if [[ "$missing" -gt 0 || "$mismatch" -gt 0 ]]; then
  echo "ERROR: assets mirror is missing or mismatched for $mirror_name"
  exit 1
fi

if [[ "$extra" -gt 0 && "$ALLOW_EXTRAS" != "true" ]]; then
  echo "ERROR: assets mirror has extra local files for $mirror_name"
  echo "Run with --sync --delete to make the project folder exactly match central assets."
  exit 1
fi

if [[ "$extra" -gt 0 ]]; then
  echo "WARN: assets mirror has $extra extra local file(s), allowed for first pass."
fi

echo "OK: assets mirror valid for $mirror_name"
