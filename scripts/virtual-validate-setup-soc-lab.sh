#!/bin/bash

set -euo pipefail

if [ -n "${TARGET_SCRIPT_PATH:-}" ]; then
TARGET_SCRIPT="$TARGET_SCRIPT_PATH"
else
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/setup-soc-lab.sh"
fi

export HOME="/tmp/elastic-virtual-run"
rm -rf "$HOME"
mkdir -p "$HOME"
cd "$HOME"

clear() { :; }
sleep() { :; }

id() {
if [ "${1:-}" = "default" ] && [ -z "${MOCK_DEFAULT_CREATED:-}" ]; then
return 1
fi

return 0
}

sudo() {
echo "[mock sudo] $*"

local CMD="${1:-}"

if [ "$CMD" = "useradd" ]; then
export MOCK_DEFAULT_CREATED=1
fi

if declare -F "$CMD" >/dev/null 2>&1; then
shift
"$CMD" "$@"
return $?
fi

return 0
}

curl() { echo "[mock curl] $*"; return 0; }
getent() { echo "[mock getent] $*"; return 0; }
docker() { echo "[mock docker] $*"; return 0; }
git() { echo "[mock git] $*"; return 0; }

pipx() {
if [ "${1:-}" = "list" ]; then
return 1
fi

echo "[mock pipx] $*"
return 0
}

dpkg() { return 1; }
filebeat() { echo "[mock filebeat] $*"; return 0; }

auditctl() {
if [ "${1:-}" = "-l" ]; then
return 1
fi

echo "[mock auditctl] $*"
return 0
}

lsof() { return 1; }

source <(tr -d '\r' < "$TARGET_SCRIPT")
