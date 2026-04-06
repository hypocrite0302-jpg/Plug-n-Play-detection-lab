#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
INSTALL_TARGET="${SOC_LAB_INSTALL_TARGET:-$ROOT_DIR/scripts/setup-soc-lab.sh}"

if [ ! -f "$INSTALL_TARGET" ]; then
echo "[ERROR] Installer target not found: $INSTALL_TARGET" >&2
exit 1
fi

TEMP_SCRIPT="$(mktemp /tmp/soc-lab-install.XXXXXX.sh)"
trap 'rm -f "$TEMP_SCRIPT"' EXIT

# Normalize CRLF on the fly so the installer works even when the repo was prepared on Windows.
tr -d '\r' < "$INSTALL_TARGET" > "$TEMP_SCRIPT"
chmod +x "$TEMP_SCRIPT"

bash "$TEMP_SCRIPT" "$@"
