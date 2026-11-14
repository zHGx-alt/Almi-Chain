#!/usr/bin/env bash
# Enables the repo's Git hooks (run once after cloning).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath scripts
chmod +x scripts/pre-commit
echo "Hooks enabled (core.hooksPath = scripts)."
