#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Build Context Archive
# ==========================================
#
# Builds a timestamped curated archive for LLM/project context.
#
# Usage:
#   .scripts/build-context-archive.sh

# ------------------------------------------
# Configuration
# ------------------------------------------

PROJECT_NAME="homepage-geoip-heatmap"
ARCHIVE_ROOT=".llm-workflows/archives"
RETENTION_COUNT=5

resolve_repo_root() {
  if [[ -n "${repo_root:-}" ]]; then
    printf '%s\n' "$repo_root"
    return 0
  fi

  git rev-parse --show-toplevel
}

prune_old_archives() {
  local resolved_repo_root
  local archive_dir

  resolved_repo_root="$(resolve_repo_root)" || return 0
  archive_dir="$resolved_repo_root/$ARCHIVE_ROOT"

  if [[ ! -d "$archive_dir" ]]; then
    return 0
  fi

  find "$archive_dir" -maxdepth 1 -type f \
    \( -name '*.tar.gz' -o -name '*.tgz' -o -name '*.zip' \) \
    -printf '%T@ %p\n' \
    | sort -rn \
    | awk -v keep="$RETENTION_COUNT" 'NR > keep { sub(/^[^ ]+ /, ""); print }' \
    | while IFS= read -r old_archive; do
        rm -f -- "$old_archive"
      done
}

cleanup_context_build() {
  local resolved_repo_root

  resolved_repo_root="$(resolve_repo_root 2>/dev/null)" || return 0

  if [[ -d "$resolved_repo_root/.context-build" ]]; then
    rm -rf -- "$resolved_repo_root/.context-build"
  fi
}




TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# ------------------------------------------
# Helpers
# ------------------------------------------

copy_path() {
  local src="$1"
  local dst="$2"

  if [[ -L "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
  elif [[ -d "$src" ]]; then
    mkdir -p "$dst"
    rsync -a       --exclude '.git/'       --exclude '.scratch/'       --exclude '.stack/'       --exclude '.archive/'       --exclude '.context-build/'       --exclude '.llm-workflows/archives/'       --exclude 'node_modules/'       --exclude '.venv/'       --exclude 'venv/'       --exclude '__pycache__/'       --exclude 'dist/'       --exclude 'build/'       --exclude 'coverage/'       --exclude '.cache/'       --exclude '*.log'       --exclude '*.tar.gz'       --exclude '*.tgz'       "$src/" "$dst/"
  elif [[ -f "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
  fi
}

include_if_exists() {
  local path="$1"
  local staging="$2"

  if [[ -e "$path" || -L "$path" ]]; then
    copy_path "$path" "$staging/$path"
  fi
}

# ------------------------------------------
# Main
# ------------------------------------------

main() {
  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"
  cd "$repo_root"

  local short_sha
  short_sha="$(git rev-parse --short HEAD 2>/dev/null || echo no-commit)"

  local archive_name
  archive_name="${PROJECT_NAME}-archive-${TIMESTAMP}-${short_sha}.tar.gz"

  local archive_path
  archive_path="${ARCHIVE_ROOT}/${archive_name}"

  local work_dir
  work_dir="$repo_root/.context-build"

  local staging
  staging="$work_dir/staging"

  rm -rf "$work_dir"
  mkdir -p "$staging" "$ARCHIVE_ROOT"

  local includes=(
    README.md
    docs
    .gitignore
    .githooks
    .scripts
    .llm-workflows/context
    .github/workflows
    src
    app
    backend
    frontend/src
    frontend/static
    frontend/package.json
    frontend/package-lock.json
    frontend/pnpm-lock.yaml
    frontend/svelte.config.js
    frontend/svelte.config.ts
    frontend/vite.config.js
    frontend/vite.config.ts
    frontend/tsconfig.json
    tests
    migrations
    alembic
    prisma
    sql
    db
    docker
    compose.yml
    docker-compose.yml
    Dockerfile
    Dockerfile.dev
    pyproject.toml
    requirements.txt
    requirements-dev.txt
    uv.lock
    package.json
    package-lock.json
    pnpm-lock.yaml
    tsconfig.json
    vite.config.js
    vite.config.ts
    svelte.config.js
    svelte.config.ts
  )

  local path
  for path in "${includes[@]}"; do
    include_if_exists "$path" "$staging"
  done

  framework_embedder="${ENGINEERING_FRAMEWORK_REPO:-/srv/docker/repos/engineering-framework}/.scripts/embed-framework-archive.sh"
  if [[ -x "$framework_embedder" ]]; then
    "$framework_embedder" "$staging"
  else
    echo "WARN: engineering-framework embedder not found: $framework_embedder" >&2
  fi

  mkdir -p "$staging/context"

  (
    cd "$staging"
    find . -type f -o -type l | sed 's#^\./##' | sort
  ) > "$staging/context/archive-manifest.txt"

  tar     --create     --gzip     --file "$archive_path"     -C "$staging"     .

  echo "Created archive:"
  echo "  $archive_path"

  echo
  echo "Archive contents preview:"
  tar -tzf "$archive_path" | sed -n '1,120p'

  echo
  echo "Sanity checks:"
  if tar -tzf "$archive_path" | grep -E '(^|/)(\.git|\.archive|\.stack|\.context-build|\.scratch|node_modules|\.venv|venv|__pycache__|dist|build|coverage)/' >/dev/null; then
    echo "ERROR: archive contains noisy paths" >&2
    return 1
  fi

  echo "OK: archive excludes noisy paths"
}
trap cleanup_context_build EXIT

main "$@"


prune_old_archives
