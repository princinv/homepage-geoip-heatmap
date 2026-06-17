#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Ensure Gitkeep Placement
# ==========================================
#
# Ensures empty intended repository directories contain `.gitkeep`,
# and removes `.gitkeep` from directories that contain real files.
#
# Generated/dependency/runtime directories are skipped.
#
# Usage:
#   .scripts/ensure-gitkeep.sh --fix
#   .scripts/ensure-gitkeep.sh --check

# ------------------------------------------
# Configuration
# ------------------------------------------

MODE="${1:---fix}"

FORCED_GITKEEP_DIRS=(
  "./.scratch"
  "./.llm-workflows/archives"
)

# ------------------------------------------
# Helpers
# ------------------------------------------

usage() {
  echo "Usage: $0 [--fix|--check]"
}

has_real_entries() {
  local dir="$1"

  find "$dir" \
    -mindepth 1 \
    -maxdepth 1 \
    ! -name '.gitkeep' \
    -print -quit | grep -q .
}

ensure_forced_dir() {
  local dir="$1"
  local failed_ref="$2"

  mkdir -p "$dir"

  if [[ "$MODE" == "--fix" ]]; then
    : > "$dir/.gitkeep"
  elif [[ ! -f "$dir/.gitkeep" ]]; then
    echo "Missing forced .gitkeep: $dir/.gitkeep"
    printf -v "$failed_ref" 1
  elif [[ -s "$dir/.gitkeep" ]]; then
    echo "Forced .gitkeep is not empty: $dir/.gitkeep"
    printf -v "$failed_ref" 1
  fi
}

# ------------------------------------------
# Main
# ------------------------------------------

main() {
  if [[ "$MODE" != "--fix" && "$MODE" != "--check" ]]; then
    usage
    exit 2
  fi

  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"
  cd "$repo_root"

  local failed=0
  local forced_dir

  for forced_dir in "${FORCED_GITKEEP_DIRS[@]}"; do
    ensure_forced_dir "$forced_dir" failed
  done

  local dir

  while IFS= read -r -d '' dir; do
    if has_real_entries "$dir"; then
      if [[ "$MODE" == "--fix" ]]; then
        rm -f "$dir/.gitkeep"
      elif [[ -e "$dir/.gitkeep" ]]; then
        echo "Remove .gitkeep from non-empty directory: $dir/.gitkeep"
        failed=1
      fi
    else
      if [[ "$MODE" == "--fix" ]]; then
        : > "$dir/.gitkeep"
      elif [[ ! -e "$dir/.gitkeep" ]]; then
        echo "Missing .gitkeep in empty directory: $dir/.gitkeep"
        failed=1
      elif [[ ! -f "$dir/.gitkeep" ]]; then
        echo ".gitkeep is not a regular file: $dir/.gitkeep"
        failed=1
      elif [[ -s "$dir/.gitkeep" ]]; then
        echo ".gitkeep is not empty: $dir/.gitkeep"
        failed=1
      fi
    fi
  done < <(
    find . \
      -path './.git' -prune -o \
      -path './.scratch' -prune -o \
      -path './.archive' -prune -o \
      -path './.context-build' -prune -o \
      -path './.llm-workflows/archives' -prune -o \
      -path './node_modules' -prune -o \
      -path './.venv' -prune -o \
      -path './venv' -prune -o \
      -path './dist' -prune -o \
      -path './build' -prune -o \
      -path './coverage' -prune -o \
      -path '*/__pycache__' -prune -o \
      -type d -print0
  )

  if [[ "$MODE" == "--check" ]]; then
    if [[ "$failed" -ne 0 ]]; then
      exit 1
    fi

    echo ".gitkeep validation passed."
  else
    echo "Ensured .gitkeep exists only in empty intended directories."
  fi
}

main "$@"
