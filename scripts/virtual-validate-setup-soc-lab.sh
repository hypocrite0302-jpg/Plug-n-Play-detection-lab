#!/usr/bin/env bash

set -euo pipefail

if [[ -n "${TARGET_SCRIPT_PATH:-}" ]]; then
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

sudo() {
  echo "[mock sudo] $*" >&2
  local cmd="${1:-}"
  if declare -F "$cmd" >/dev/null 2>&1; then
    shift
    "$cmd" "$@"
    return $?
  fi
  return 0
}

lsof() {
  return 1
}

dpkg() {
  if [[ "${1:-}" == "-s" ]]; then
    return 0
  fi
  echo "[mock dpkg] $*" >&2
  return 0
}

apt-get() {
  echo "[mock apt-get] $*" >&2
  return 0
}

git() {
  echo "[mock git] $*" >&2
  if [[ "${1:-}" == "clone" ]]; then
    local target="${3:-}"
    mkdir -p "$target/.git"
  fi
  return 0
}

pipx() {
  echo "[mock pipx] $*" >&2
  return 0
}

jq() {
  if [[ "${1:-}" == "-n" ]]; then
    printf '{}\n'
    return 0
  fi

  if [[ "${1:-}" == "-Rn" && "${2:-}" == "--arg" && "${3:-}" == "value" ]]; then
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "${4:-}"
    return 0
  fi

  local raw=0
  local exit_status_mode=0
  if [[ "${1:-}" == "-e" ]]; then
    exit_status_mode=1
    shift
  fi
  if [[ "${1:-}" == "-r" ]]; then
    raw=1
    shift
  fi

  local expr="${1:-}"
  local payload
  payload="$(cat)"

  python3 -c '
import json
import sys

expr = sys.argv[1]
raw = sys.argv[2] == "1"
data = json.loads(sys.argv[3])

def emit(value):
    if raw and not isinstance(value, (dict, list, bool)):
        print("" if value is None else value)
    else:
        print(json.dumps(value))

if expr == ".value":
    emit(data.get("value"))
elif expr == ".item.api_key":
    emit(data.get("item", {}).get("api_key"))
elif expr == ".status":
    emit(data.get("status"))
elif expr == ".status // \"unknown\"":
    emit(data.get("status", "unknown"))
elif expr == ".status.overall.level // .overall.level // \"unknown\"":
    status = data.get("status", {})
    emit(status.get("overall", {}).get("level") or data.get("overall", {}).get("level") or "unknown")
elif expr == "[.data_streams[]?.name] | map(select(test(\"^(logs|metrics)-\"))) | length":
    names = [item.get("name", "") for item in data.get("data_streams", [])]
    emit(len([name for name in names if name.startswith(("logs-", "metrics-"))]))
elif expr == ".data_streams | length > 0":
    emit(len(data.get("data_streams", [])) > 0)
elif expr == "length > 0":
    emit(len(data) > 0)
elif expr == ".items[]? | select(.active == true)":
    items = data.get("items", [])
    sys.exit(0 if any(item.get("active") is True for item in items) else 1)
else:
    raise SystemExit(f"Unsupported jq expression in validator: {expr}")
' "$expr" "$raw" "$payload"
}

sysctl() {
  if [[ "${1:-}" == "-n" && "${2:-}" == "vm.max_map_count" ]]; then
    printf '1048576\n'
    return 0
  fi
  if [[ "${1:-}" == "-w" && "${2:-}" == "vm.max_map_count=1048576" ]]; then
    printf 'vm.max_map_count = 1048576\n'
    return 0
  fi
  command sysctl "$@"
}

docker() {
  local subcommand="${1:-}"
  shift || true

  case "$subcommand" in
    compose)
      if [[ "${1:-}" == "version" ]]; then
        printf 'Docker Compose version v2.32.0\n'
        return 0
      fi
      echo "[mock docker compose] $*" >&2
      return 0
      ;;
    info)
      printf 'Mock Docker info\n'
      return 0
      ;;
    ps)
      if [[ " $* " == *" -aq "* ]]; then
        return 0
      fi
      return 0
      ;;
    volume)
      if [[ "${1:-}" == "ls" ]]; then
        return 0
      fi
      echo "[mock docker volume] $*" >&2
      return 0
      ;;
    network)
      if [[ "${1:-}" == "ls" && "${2:-}" == "-q" ]]; then
        printf 'bridge\n'
        return 0
      fi
      if [[ "${1:-}" == "ls" && "${2:-}" == "--format" ]]; then
        printf 'bridge\nhost\nnone\n'
        return 0
      fi
      if [[ "${1:-}" == "inspect" && "${2:-}" == "bridge" ]]; then
        printf '172.17.0.0/16\n'
        return 0
      fi
      echo "[mock docker network] $*" >&2
      return 0
      ;;
    inspect)
      if [[ "${1:-}" == "-f" ]]; then
        return 0
      fi
      echo "[mock docker inspect] $*" >&2
      return 0
      ;;
    rm|rmi)
      echo "[mock docker $subcommand] $*" >&2
      return 0
      ;;
    *)
      echo "[mock docker $subcommand] $*" >&2
      return 0
      ;;
  esac
}

curl() {
  local args="$*"

  if [[ "$args" == *"https://localhost:"*"/api/status"* && "$args" == *"--cacert"* ]]; then
    printf '{"status":"HEALTHY"}\n'
    return 0
  fi

  case "$args" in
    *"/_cluster/health"*)
      printf '{"status":"green"}\n'
      return 0
      ;;
    *"/_security/user/kibana_system/_password"*)
      printf '{"acknowledged":true}\n'
      return 0
      ;;
    *"/_data_stream"*)
      if [[ "$args" == *"filebeat-"* ]]; then
        printf '{"data_streams":[{"name":"filebeat-8.12.2"}]}\n'
      else
        printf '{"data_streams":[{"name":"logs-system.default"},{"name":"metrics-system.default"}]}\n'
      fi
      return 0
      ;;
    *"/_cat/indices/filebeat-"*)
      printf '[{"health":"green","status":"open","index":"filebeat-8.12.2-000001"}]\n'
      return 0
      ;;
    *"http://localhost:"*"/api/status"*)
      printf '{"status":{"overall":{"level":"available"}},"overall":{"level":"available"}}\n'
      return 0
      ;;
  esac

  echo "[mock curl] $*" >&2
  return 0
}

export SOC_LAB_ROOT="$HOME/lab-runtime"
export NONINTERACTIVE=1

source "$TARGET_SCRIPT" --yes --force-rebuild

LAB_ROOT="$HOME/soc-lab"

test -f "$LAB_ROOT/docker-compose.yml"
test -f "$LAB_ROOT/.credentials.env"

grep -q 'xpack.security.enabled: "true"' "$LAB_ROOT/docker-compose.yml"
grep -q 'ELASTICSEARCH_USERNAME: "kibana_system"' "$LAB_ROOT/docker-compose.yml"
grep -q 'FLEET_SERVER_ELASTICSEARCH_USERNAME: "elastic"' "$LAB_ROOT/docker-compose.yml"
grep -q '^ELASTIC_PASSWORD=' "$LAB_ROOT/.credentials.env"
grep -q '^KIBANA_LOGIN_USERNAME=' "$LAB_ROOT/.credentials.env"

printf '\n[virtual-validate] installer mock run completed successfully\n'
