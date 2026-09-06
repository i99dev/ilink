#!/usr/bin/env bash
# Run once after cloning to point git at the in-repo hooks dir.
# Idempotent — safe to re-run.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit
echo "✓ hooks installed (core.hooksPath=.githooks)"
echo "  pre-commit will block commits on dart format / flutter analyze /"
echo "  audit_hex failures."
