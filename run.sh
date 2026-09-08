#!/usr/bin/env bash
# Lance la veille alternance finance (Linux / macOS / Git Bash). Necessite PowerShell 7 (pwsh).
# Usage : ./run.sh [ -Since 12 ] [ -Strict ] [ -All ]
set -euo pipefail
cd "$(dirname "$0")"
exec pwsh -NoProfile -File ./alternance.ps1 "$@"
