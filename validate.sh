#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="${SOC_LAB_REPO_ROOT:-$SCRIPT_DIR}"
EXPECTED_VERSION="${SOC_LAB_ELASTIC_VERSION:-8.12.2}"
LAB_ROOT="${SOC_LAB_RUNTIME_ROOT:-$HOME/soc-lab}"
AUTO_APPROVE=0
DRY_RUN=0
DEEP_CLEAN=0
CREDENTIALS_ENV_FILE=""
ELASTIC_PASSWORD=""
KIBANA_LOGIN_USERNAME=""
KIBANA_LOGIN_PASSWORD=""

PORTS=(9200 5601 8220)
CONTAINERS=(elasticsearch kibana fleet-server)
LAB_VOLUMES=(soc-lab_esdata)
LAB_NETWORKS=(soc-lab_default)
LAB_DIR_CANDIDATES=("$HOME/soc-lab" "$HOME/elastic-lab")
LAB_DOWNLOAD_GLOBS=("$HOME/filebeat-*.deb" "$HOME/soc-lab/filebeat-*.deb" "$HOME/elastic-lab/filebeat-*.deb")
LAB_MISC_PATHS=("$HOME/atomic-red-team" "$HOME/mitre")

STATE="unknown"
SUMMARY=()
WARNINGS=()
BLOCKERS=()
OBSOLETE=()
ACCESS_NOTES=()
UNRELATED_PORT_BLOCKERS=()
ES_ENDPOINT=""
KIBANA_ENDPOINT=""
FLEET_ENDPOINT=""

C_RESET="$(printf '\033[0m')"
C_BOLD="$(printf '\033[1m')"
C_RED="$(printf '\033[31m')"
C_GREEN="$(printf '\033[32m')"
C_YELLOW="$(printf '\033[33m')"
C_BLUE="$(printf '\033[34m')"
C_MAGENTA="$(printf '\033[35m')"

banner() {
  cat <<'EOF'

   _________  ________  _________   __    ___   ___   ____
  / ___/ __ \/ ____/ / / / __/ _ | / /   / _ | / _ ) / __/
 (__  ) /_/ / /   / /_/ / _// __ |/ /__ / __ |/ _  |_\ \
/____/\____/_/    \____/___/_/ |_/____//_/ |_/____/___/

        SOC Lab State Validator And Rebuild Prep

EOF
}

info() { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$1"; }
ok() { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
fail() { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; exit 1; }
section() { printf '\n%s%s[%s]%s %s\n' "$C_BOLD" "$C_MAGENTA" "$1" "$C_RESET" "$2"; }

usage() {
  cat <<EOF
Usage: bash validate.sh [OPTIONS]

Options:
  --lab-root PATH      Runtime lab directory to inspect (default: $HOME/soc-lab)
  --deep-clean         Also remove Filebeat, lab telemetry rules, and cloned datasets
  --dry-run            Show what would be changed without deleting anything
  --yes, -y            Non-interactive mode; delete blockers without prompting
  -h, --help           Show this help text
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lab-root)
        shift
        LAB_ROOT="${1:-}"
        ;;
      --deep-clean)
        DEEP_CLEAN=1
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      --yes|-y)
        AUTO_APPROVE=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
    shift
  done
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

is_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

can_sudo_noninteractive() {
  have_cmd sudo && sudo -n true >/dev/null 2>&1
}

run_cmd() {
  if (( DRY_RUN )); then
    local rendered
    rendered="$(printf '%q ' "$@")"
    printf '%s[DRY ]%s %s\n' "$C_YELLOW" "$C_RESET" "${rendered% }"
    return 0
  fi

  "$@"
}

prompt_choice() {
  local prompt="$1"
  local default_choice="$2"
  local reply

  if (( AUTO_APPROVE )); then
    printf '%s\n' "$default_choice"
    return 0
  fi

  read -r -p "$prompt" reply
  reply="${reply:-$default_choice}"
  printf '%s\n' "$reply"
}

record_summary() { SUMMARY+=("$1"); }
record_warning() { WARNINGS+=("$1"); }
record_blocker() { BLOCKERS+=("$1"); }
record_obsolete() { OBSOLETE+=("$1"); }
record_access() { ACCESS_NOTES+=("$1"); }

load_runtime_credentials() {
  CREDENTIALS_ENV_FILE="$LAB_ROOT/.credentials.env"

  if [[ -f "$CREDENTIALS_ENV_FILE" ]]; then
    set -a
    . "$CREDENTIALS_ENV_FILE"
    set +a
    record_summary "Credential file present: $CREDENTIALS_ENV_FILE"
  fi
}

audit_rule_present() {
  have_cmd auditctl || return 1

  if is_root; then
    auditctl -l 2>/dev/null | grep -q 'exec_log'
    return $?
  fi

  if can_sudo_noninteractive; then
    sudo -n auditctl -l 2>/dev/null | grep -q 'exec_log'
    return $?
  fi

  return 2
}

detect_repo_version() {
  local compose_file="$REPO_ROOT/elastic-lab/docker-compose.yml"
  if [[ -f "$compose_file" ]]; then
    local version
    version="$(sed -n 's/.*elasticsearch\/elasticsearch:\([0-9.]*\).*/\1/p' "$compose_file" | head -1)"
    if [[ -n "$version" ]]; then
      EXPECTED_VERSION="$version"
    fi
  fi
}

validate_host() {
  section "1/6" "Host Validation"

  [[ "$(uname -s)" == "Linux" ]] || fail "This validator is designed for Linux or WSL."
  ok "Linux environment detected"

  if grep -qi microsoft /proc/version 2>/dev/null; then
    info "WSL environment detected"
  fi

  detect_repo_version
  info "Expected Elastic version: $EXPECTED_VERSION"
}

docker_available() {
  have_cmd docker && docker info >/dev/null 2>&1
}

capture_container_status() {
  local name="$1"
  docker ps -a --filter "name=^/${name}$" --format '{{.Names}}|{{.Status}}|{{.Image}}' 2>/dev/null | head -1 || true
}

port_listener() {
  local port="$1"

  if have_cmd lsof; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1 " pid=" $2 " user=" $3}' | paste -sd ';' - || true
    return 0
  fi

  if have_cmd ss; then
    ss -ltnp "sport = :$port" 2>/dev/null | awk 'NR>1 {print $0}' | paste -sd ';' - || true
  fi
}

scan_ports() {
  section "2/6" "Port And Process Scan"

  local port
  for port in "${PORTS[@]}"; do
    local listener
    listener="$(port_listener "$port")"

    if [[ -z "$listener" ]]; then
      record_summary "Port $port is free"
      continue
    fi

    if [[ "$listener" == *docker-proxy* || "$listener" == *com.docker.backend* || "$listener" == *rootlesskit* ]]; then
      record_summary "Port $port is bound by Docker: $listener"
    else
      record_blocker "Port $port is already in use by: $listener"
      UNRELATED_PORT_BLOCKERS+=("$port:$listener")
    fi
  done
}

scan_docker_state() {
  section "3/6" "Docker State"

  if ! have_cmd docker; then
    record_blocker "Docker is not installed or not in PATH"
    return 0
  fi

  if ! docker_available; then
    record_blocker "Docker is installed but the daemon is not reachable"
    return 0
  fi

  ok "Docker daemon is reachable"

  local running_count=0
  local present_count=0
  local name
  for name in "${CONTAINERS[@]}"; do
    local status_line
    status_line="$(capture_container_status "$name")"
    if [[ -z "$status_line" ]]; then
      record_summary "Container '$name' not present"
      continue
    fi

    present_count=$((present_count + 1))
    local status image
    status="$(printf '%s' "$status_line" | cut -d'|' -f2)"
    image="$(printf '%s' "$status_line" | cut -d'|' -f3)"

    if [[ "$status" == Up* ]]; then
      running_count=$((running_count + 1))
      record_summary "Container '$name' is running"
    else
      record_obsolete "Container '$name' exists but is not healthy for reuse: $status"
    fi

    if [[ "$image" != *":$EXPECTED_VERSION" ]]; then
      record_obsolete "Container '$name' is pinned to unexpected image '$image'"
    fi
  done

  local volume
  for volume in "${LAB_VOLUMES[@]}"; do
    if docker volume inspect "$volume" >/dev/null 2>&1; then
      if (( present_count == 0 )); then
        record_obsolete "Volume '$volume' exists without active lab containers"
      else
        record_summary "Volume '$volume' present"
      fi
    fi
  done

  local network
  for network in "${LAB_NETWORKS[@]}"; do
    if docker network inspect "$network" >/dev/null 2>&1; then
      if (( present_count == 0 )); then
        record_obsolete "Network '$network' exists without active lab containers"
      else
        record_summary "Network '$network' present"
      fi
    fi
  done

  if (( running_count == ${#CONTAINERS[@]} )); then
    record_access "Docker stack is up with Elasticsearch, Kibana, and Fleet Server"
  elif (( running_count > 0 )); then
    record_warning "Docker stack is only partially running ($running_count/${#CONTAINERS[@]})"
  else
    record_warning "No active SOC lab containers are running"
  fi
}

http_ok() {
  local url="$1"
  shift || true
  curl "$@" -fsS --max-time 5 "$url" >/dev/null 2>&1
}

detect_endpoint() {
  local endpoint
  for endpoint in "$@"; do
    local url="${endpoint%%|*}"
    local mode="${endpoint##*|}"

    case "$mode" in
      http)
        if http_ok "$url"; then
          printf '%s\n' "$url"
          return 0
        fi
        ;;
      https-insecure)
        if http_ok "$url" -k; then
          printf '%s\n' "$url"
          return 0
        fi
        ;;
    esac
  done

  return 1
}

scan_runtime_paths() {
  section "4/6" "Runtime Paths And Artifacts"

  if [[ -d "$LAB_ROOT" ]]; then
    record_summary "Primary runtime directory present: $LAB_ROOT"
    if [[ -f "$LAB_ROOT/docker-compose.yml" ]]; then
      record_summary "Runtime docker-compose.yml present in $LAB_ROOT"
    fi
  else
    record_warning "Primary runtime directory not found: $LAB_ROOT"
  fi

  load_runtime_credentials

  local candidate
  for candidate in "${LAB_DIR_CANDIDATES[@]}"; do
    [[ "$candidate" == "$LAB_ROOT" ]] && continue
    if [[ -d "$candidate" ]]; then
      record_obsolete "Legacy runtime directory detected: $candidate"
    fi
  done

  local glob
  for glob in "${LAB_DOWNLOAD_GLOBS[@]}"; do
    local found=0
    local path
    for path in $glob; do
      if [[ -f "$path" ]]; then
        found=1
        record_obsolete "Downloaded package artifact present: $path"
      fi
    done
    (( found )) && true
  done

  local misc_path
  for misc_path in "${LAB_MISC_PATHS[@]}"; do
    if [[ -e "$misc_path" ]]; then
      record_summary "Supporting lab path present: $misc_path"
    fi
  done
}

scan_host_integrations() {
  section "5/6" "Host Integrations"

  if have_cmd dpkg-query && dpkg-query -W -f='${Status} ${Version}\n' filebeat 2>/dev/null | grep -q '^install ok installed '; then
    local fb_version
    fb_version="$(dpkg-query -W -f='${Version}\n' filebeat 2>/dev/null | head -1)"
    record_summary "Filebeat package installed: $fb_version"

    if [[ "$fb_version" != "$EXPECTED_VERSION"* ]]; then
      record_obsolete "Filebeat version '$fb_version' differs from expected '$EXPECTED_VERSION'"
    fi

    if have_cmd systemctl && systemctl is-active --quiet filebeat 2>/dev/null; then
      record_summary "Filebeat service is active"
    elif have_cmd service && service filebeat status >/dev/null 2>&1; then
      record_summary "Filebeat service appears to be configured"
    else
      record_obsolete "Filebeat package is installed but the service is not active"
    fi
  else
    record_warning "Filebeat package is not installed"
  fi

  if have_cmd auditctl; then
    if audit_rule_present; then
      record_summary "Auditd exec_log rule is active"
    else
      case "$?" in
        1) record_warning "Auditd exec_log rule is not active" ;;
        2) record_warning "Auditd rule state requires sudo; skipped in non-blocking mode" ;;
      esac
    fi
  else
    record_warning "auditctl not found; process telemetry state not inspected"
  fi

  if have_cmd pipx && pipx list 2>/dev/null | grep -q 'package sigma-cli '; then
    record_summary "sigma-cli is installed through pipx"
  fi
}

scan_http_health() {
  section "6/6" "Service Health"

  if [[ -n "$ELASTIC_PASSWORD" ]]; then
    if http_ok "http://127.0.0.1:9200" -u "elastic:${ELASTIC_PASSWORD}"; then
      ES_ENDPOINT="http://127.0.0.1:9200"
    else
      ES_ENDPOINT="$(detect_endpoint \
        "https://127.0.0.1:19200|https-insecure" \
        "https://127.0.0.1:9200|https-insecure" || true)"
    fi
  else
    ES_ENDPOINT="$(detect_endpoint \
      "http://127.0.0.1:9200|http" \
      "https://127.0.0.1:19200|https-insecure" \
      "https://127.0.0.1:9200|https-insecure" || true)"
  fi

  if [[ -n "$ES_ENDPOINT" ]]; then
    record_access "Elasticsearch reachable at $ES_ENDPOINT"
  else
    record_warning "Elasticsearch is not responding on the known lab ports"
  fi

  if [[ -n "$KIBANA_LOGIN_USERNAME" && -n "$KIBANA_LOGIN_PASSWORD" ]]; then
    if http_ok "http://127.0.0.1:5601/api/status" -u "${KIBANA_LOGIN_USERNAME}:${KIBANA_LOGIN_PASSWORD}"; then
      KIBANA_ENDPOINT="http://127.0.0.1:5601/api/status"
    elif http_ok "http://127.0.0.1:15601/api/status" -u "${KIBANA_LOGIN_USERNAME}:${KIBANA_LOGIN_PASSWORD}"; then
      KIBANA_ENDPOINT="http://127.0.0.1:15601/api/status"
    else
      KIBANA_ENDPOINT=""
    fi
  else
    KIBANA_ENDPOINT="$(detect_endpoint \
      "http://127.0.0.1:5601/api/status|http" \
      "http://127.0.0.1:15601/api/status|http" || true)"
  fi

  if [[ -n "$KIBANA_ENDPOINT" ]]; then
    record_access "Kibana reachable at ${KIBANA_ENDPOINT%/api/status}"
  else
    record_warning "Kibana is not responding on the known lab ports"
  fi

  FLEET_ENDPOINT="$(detect_endpoint \
    "http://127.0.0.1:8220|http" \
    "https://127.0.0.1:18220|https-insecure" \
    "https://127.0.0.1:8220|https-insecure" || true)"
  if [[ -n "$FLEET_ENDPOINT" ]]; then
    record_access "Fleet Server reachable at $FLEET_ENDPOINT"
  else
    record_warning "Fleet Server is not responding on the known lab ports"
  fi
}

determine_state() {
  local has_compose=0
  local active_services=0

  [[ -f "$LAB_ROOT/docker-compose.yml" ]] && has_compose=1
  [[ -n "$ES_ENDPOINT" ]] && active_services=$((active_services + 1))
  [[ -n "$KIBANA_ENDPOINT" ]] && active_services=$((active_services + 1))
  [[ -n "$FLEET_ENDPOINT" ]] && active_services=$((active_services + 1))

  if (( active_services == 3 )) && (( has_compose == 1 )); then
    STATE="healthy"
  elif (( active_services > 0 )) || (( ${#OBSOLETE[@]} > 0 )) || [[ -d "$LAB_ROOT" ]]; then
    STATE="degraded"
  else
    STATE="absent"
  fi
}

print_array() {
  local heading="$1"
  shift
  local -a items=("$@")

  (( ${#items[@]} == 0 )) && return 0

  printf '\n%s%s%s\n' "$C_BOLD" "$heading" "$C_RESET"
  local item
  for item in "${items[@]}"; do
    printf ' - %s\n' "$item"
  done
}

render_summary() {
  determine_state

  printf '\n%s%sSystem State:%s %s\n' "$C_BOLD" "$C_BLUE" "$C_RESET" "$STATE"
  print_array "Findings" "${SUMMARY[@]}"
  print_array "Warnings" "${WARNINGS[@]}"
  print_array "Obsolete / Stale Artifacts" "${OBSOLETE[@]}"
  print_array "Actionable Access Notes" "${ACCESS_NOTES[@]}"
  print_array "Blockers" "${BLOCKERS[@]}"

  case "$STATE" in
    healthy) ok "The current detection lab looks reusable." ;;
    degraded) warn "The lab exists but needs cleanup or repair before a confident rebuild." ;;
    absent) info "No reusable lab was detected. The system is a good candidate for a fresh build." ;;
  esac
}

remove_file_if_present() {
  local target="$1"
  [[ -e "$target" ]] || return 0
  run_cmd rm -rf "$target"
}

cleanup_docker() {
  if ! docker_available; then
    warn "Skipping Docker cleanup because Docker is unavailable"
    return 0
  fi

  info "Removing lab-owned Docker resources"

  if [[ -f "$LAB_ROOT/docker-compose.yml" ]]; then
    (cd "$LAB_ROOT" && run_cmd docker compose down -v --remove-orphans) || true
  fi

  local name
  for name in "${CONTAINERS[@]}"; do
    if docker ps -a --filter "name=^/${name}$" --format '{{.Names}}' | grep -qx "$name"; then
      run_cmd docker rm -f "$name" || true
    fi
  done

  local volume
  for volume in "${LAB_VOLUMES[@]}"; do
    if docker volume inspect "$volume" >/dev/null 2>&1; then
      run_cmd docker volume rm -f "$volume" || true
    fi
  done

  local network
  for network in "${LAB_NETWORKS[@]}"; do
    if docker network inspect "$network" >/dev/null 2>&1; then
      run_cmd docker network rm "$network" || true
    fi
  done
}

cleanup_runtime_files() {
  info "Removing lab runtime directories and downloaded package artifacts"

  local candidate
  for candidate in "${LAB_DIR_CANDIDATES[@]}"; do
    if [[ -d "$candidate" ]]; then
      remove_file_if_present "$candidate"
    fi
  done

  local glob
  for glob in "${LAB_DOWNLOAD_GLOBS[@]}"; do
    local path
    for path in $glob; do
      [[ -e "$path" ]] || continue
      remove_file_if_present "$path"
    done
  done
}

cleanup_host_integrations() {
  (( DEEP_CLEAN )) || return 0

  info "Deep-clean enabled: removing host telemetry components"

  if have_cmd systemctl; then
    run_cmd sudo systemctl stop filebeat || true
    run_cmd sudo systemctl disable filebeat || true
  elif have_cmd service; then
    run_cmd sudo service filebeat stop || true
  fi

  if have_cmd dpkg-query && dpkg-query -W -f='${Status}\n' filebeat 2>/dev/null | grep -q '^install ok installed$'; then
    run_cmd sudo apt-get purge -y filebeat || true
  fi

  [[ -d /etc/filebeat ]] && run_cmd sudo rm -rf /etc/filebeat
  [[ -d /var/lib/filebeat ]] && run_cmd sudo rm -rf /var/lib/filebeat

  if audit_rule_present; then
    if is_root; then
      run_cmd auditctl -d always,exit -F arch=b64 -S execve -k exec_log || true
    else
      run_cmd sudo auditctl -d always,exit -F arch=b64 -S execve -k exec_log || true
    fi
  fi

  local misc_path
  for misc_path in "${LAB_MISC_PATHS[@]}"; do
    if [[ -e "$misc_path" ]]; then
      remove_file_if_present "$misc_path"
    fi
  done
}

warn_on_unrelated_blockers() {
  (( ${#UNRELATED_PORT_BLOCKERS[@]} == 0 )) && return 0

  warn "Some required ports are in use by processes that do not look lab-owned."
  warn "This script will not terminate unrelated services automatically."

  local blocker
  for blocker in "${UNRELATED_PORT_BLOCKERS[@]}"; do
    printf ' - %s\n' "$blocker"
  done
}

perform_cleanup() {
  section "Cleanup" "Lab-Owned Artifact Removal"
  warn_on_unrelated_blockers

  cleanup_docker
  cleanup_runtime_files
  cleanup_host_integrations
  ok "Cleanup phase completed"
}

maybe_prompt_after_scan() {
  local answer

  if (( AUTO_APPROVE )); then
    answer="d"
  else
    answer="$(prompt_choice "Next step: [d]elete blockers or [q]uit (default: q): " "q")"
  fi

  case "$answer" in
    d|D)
      perform_cleanup
      ;;
    *)
      info "Leaving the environment unchanged"
      ;;
  esac
}

main() {
  parse_args "$@"

  if [[ -t 1 ]]; then
    clear || true
  fi

  banner
  validate_host
  scan_ports
  scan_docker_state
  scan_runtime_paths
  scan_host_integrations
  scan_http_health
  render_summary
  maybe_prompt_after_scan
}

main "$@"
