#!/usr/bin/env bash

set -u

ASSETS_MIRROR_ROOT="${ASSETS_MIRROR_ROOT:-/srv/docker/repos/assets}"
MODE="check"
CONFLICT_POLICY="fail"
VERBOSE="false"

usage() {
  cat <<'USAGE'
Usage:
  .scripts/sync-assets-mirror.sh --check [--verbose]
  .scripts/sync-assets-mirror.sh --sync [--prefer-central|--prefer-local] [--verbose]

Central assets folder:
  /srv/docker/repos/assets/<repo-name>/

Project assets folder:
  <repo>/assets/

Behavior:
  --check
      Strict equality check. Relative paths and file contents must match.

  --sync
      Bidirectional union sync. Files that exist only on one side are copied to
      the other side. Same relative path with different contents is a conflict.

  --prefer-central
      During --sync, central assets overwrite project assets on conflicts.

  --prefer-local
      During --sync, project assets overwrite central assets on conflicts.

Notes:
  Deletions are not inferred bidirectionally. Delete intentionally from both
  sides, or resolve with an explicit prefer mode if there is a content conflict.
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
    --prefer-central)
      CONFLICT_POLICY="central"
      ;;
    --prefer-local)
      CONFLICT_POLICY="local"
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

copy_file() {
  local source_file="$1"
  local target_file="$2"

  mkdir -p "$(dirname "$target_file")"
  cp -a -- "$source_file" "$target_file"
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
  local_count="$(
    find "$local_dir" -type f ! -name '.gitkeep' 2>/dev/null | wc -l
  )"

  if [[ "$local_count" -eq 0 ]]; then
    echo "SKIP: no central assets folder for $mirror_name"
    exit 0
  fi

  if [[ "$MODE" == "sync" ]]; then
    mkdir -p "$central_dir"
    echo "Created central assets folder for $mirror_name: $central_dir"
  else
    echo "ERROR: local assets exist but central folder is missing for $mirror_name"
    echo "Run --sync to create/populate the central folder, or create it manually."
    exit 1
  fi
fi

mkdir -p "$local_dir" "$central_dir"

declare -A rels=()

while IFS= read -r -d '' central_file; do
  rel="${central_file#"$central_dir/"}"
  rels["$rel"]=1
done < <(find "$central_dir" -type f ! -name '.gitkeep' -print0 | sort -z)

while IFS= read -r -d '' local_file; do
  rel="${local_file#"$local_dir/"}"
  rels["$rel"]=1
done < <(find "$local_dir" -type f ! -name '.gitkeep' -print0 | sort -z)

if [[ "${#rels[@]}" -eq 0 ]]; then
  echo "OK: no real assets for $mirror_name"
  exit 0
fi

changes=0
problems=0

for rel in "${(@k)rels}"; do
  central_file="$central_dir/$rel"
  local_file="$local_dir/$rel"

  central_exists="false"
  local_exists="false"

  [[ -f "$central_file" ]] && central_exists="true"
  [[ -f "$local_file" ]] && local_exists="true"

  if [[ "$central_exists" == "true" && "$local_exists" == "true" ]]; then
    central_sha="$(sha_file "$central_file")"
    local_sha="$(sha_file "$local_file")"

    if [[ "$central_sha" == "$local_sha" ]]; then
      if [[ "$VERBOSE" == "true" ]]; then
        echo "OK: assets/$rel"
      fi
      continue
    fi

    if [[ "$MODE" == "sync" && "$CONFLICT_POLICY" == "central" ]]; then
      copy_file "$central_file" "$local_file"
      echo "UPDATED FROM CENTRAL: assets/$rel"
      changes=$((changes + 1))
      continue
    fi

    if [[ "$MODE" == "sync" && "$CONFLICT_POLICY" == "local" ]]; then
      copy_file "$local_file" "$central_file"
      echo "UPDATED FROM LOCAL: assets/$rel"
      changes=$((changes + 1))
      continue
    fi

    echo "CONFLICT: assets/$rel differs between central and local"
    echo "  central: $central_file"
    echo "  local:   $local_file"
    echo "Resolve manually, or rerun --sync with --prefer-central or --prefer-local."
    problems=$((problems + 1))
    continue
  fi

  if [[ "$central_exists" == "true" && "$local_exists" != "true" ]]; then
    if [[ "$MODE" == "sync" ]]; then
      copy_file "$central_file" "$local_file"
      echo "COPIED TO LOCAL: assets/$rel"
      changes=$((changes + 1))
    else
      echo "MISSING LOCAL: assets/$rel"
      problems=$((problems + 1))
    fi
    continue
  fi

  if [[ "$local_exists" == "true" && "$central_exists" != "true" ]]; then
    if [[ "$MODE" == "sync" ]]; then
      copy_file "$local_file" "$central_file"
      echo "COPIED TO CENTRAL: assets/$rel"
      changes=$((changes + 1))
    else
      echo "MISSING CENTRAL: assets/$rel"
      problems=$((problems + 1))
    fi
    continue
  fi
done

if [[ "$MODE" == "sync" && "$changes" -gt 0 ]]; then
  echo "Synced $changes asset file(s) for $mirror_name"
fi

if [[ "$problems" -gt 0 ]]; then
  echo "ERROR: assets mirror is not synchronized for $mirror_name"
  exit 1
fi

echo "OK: assets mirror valid for $mirror_name"
