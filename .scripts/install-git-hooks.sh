#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Install Git Hooks
# ==========================================
#
# Configures this repository to use managed Git hooks from `.githooks/`.
#
# Usage:
#   .scripts/install-git-hooks.sh

# ------------------------------------------
# Main
# ------------------------------------------

main() {
  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"
  cd "$repo_root"

  git config core.hooksPath .githooks

  chmod +x .githooks/pre-commit
  chmod +x .githooks/post-commit

  echo "Configured Git hooks path:"
  git config --get core.hooksPath

  echo
  echo "Installed hooks:"
  find .githooks -maxdepth 1 -type f -printf '  %p\n' | sort
}

main "$@"
