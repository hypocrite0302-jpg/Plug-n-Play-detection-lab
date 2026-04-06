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
echo "[mock sudo] $*" >&2

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
git() { echo "[mock git] $*"; return 0; }

docker() {
local SUBCOMMAND="${1:-}"

if [ "$SUBCOMMAND" = "ps" ]; then
local FILTER=""

shift

while [ $# -gt 0 ]; do
if [ "$1" = "-f" ] || [ "$1" = "--filter" ]; then
FILTER="${2:-}"
shift 2
continue
fi

shift
done

if [ -n "${MOCK_CONTAINER_CONFLICT_NAME:-}" ] && [ "$FILTER" = "name=^/${MOCK_CONTAINER_CONFLICT_NAME}$" ]; then
printf '%s\n' "${MOCK_CONTAINER_CONFLICT_ID:-mock-conflict-id}"
fi

return 0
fi

if [ "$SUBCOMMAND" = "inspect" ] && [ "${2:-}" = "-f" ]; then
local TARGET="${4:-}"

if [ "$TARGET" = "${MOCK_CONTAINER_CONFLICT_ID:-mock-conflict-id}" ]; then
printf '%s\n' "${MOCK_CONTAINER_CONFLICT_IMAGE:-docker.elastic.co/elasticsearch/elasticsearch:8.12.2}"
fi

return 0
fi

if [ "$SUBCOMMAND" = "rm" ] && [ "${2:-}" = "-f" ]; then
local TARGET="${3:-}"

echo "[mock docker] $*"

if [ "$TARGET" = "${MOCK_CONTAINER_CONFLICT_ID:-mock-conflict-id}" ] || [ "$TARGET" = "${MOCK_CONTAINER_CONFLICT_NAME:-}" ]; then
unset MOCK_CONTAINER_CONFLICT_NAME
unset MOCK_CONTAINER_CONFLICT_ID
unset MOCK_CONTAINER_CONFLICT_IMAGE
fi

return 0
fi

if [ "$SUBCOMMAND" = "info" ]; then
return 0
fi

echo "[mock docker] $*"
return 0
}

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
