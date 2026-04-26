#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# Deploy Filebeat Agent — End-to-End Elastic Lab Log Forwarding
# This script detects a running Elastic Stack (via Docker), extracts credentials,
# installs Filebeat, configures real-time log forwarding, and validates delivery.
#
# Usage:
#   sudo bash deploy-filebeat-agent.sh [--lab-root /path/to/elastic-lab] [--yes]

LAB_ROOT="${SOC_LAB_ROOT:-}"
AUTO_APPROVE=0

# Color output
C_RESET="$(printf '\033[0m')"
C_BOLD="$(printf '\033[1m')"
C_RED="$(printf '\033[31m')"
C_GREEN="$(printf '\033[32m')"
C_YELLOW="$(printf '\033[33m')"
C_BLUE="$(printf '\033[34m')"

info() { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$1"; }
ok() { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
fail() { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; exit 1; }
section() { printf '\n%s%s[%s]%s %s\n' "$C_BOLD" "$C_BLUE" "$1" "$C_RESET" "$2"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lab-root) shift; LAB_ROOT="${1:?missing value for --lab-root}" ;;
      --yes|-y) AUTO_APPROVE=1 ;;
      -h|--help) usage; exit 0 ;;
      *) fail "Unknown argument: $1" ;;
    esac
    shift
  done
}

usage() {
  cat <<EOF
Usage: sudo bash deploy-filebeat-agent.sh [OPTIONS]

Options:
  --lab-root PATH    Path to Elastic lab root (defaults to auto-detect)
  --yes              Non-interactive mode; accept defaults
  -h, --help         Show this help text
EOF
}

is_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] && return 0 || return 1
}

validate_linux() {
  [[ "$(uname -s)" == "Linux" ]] || fail "This script supports Linux (WSL/native) only."
  ok "Running on Linux"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

find_lab_root() {
  section "1/8" "Locate Elastic Lab Root"

  if [[ -n "$LAB_ROOT" && -d "$LAB_ROOT" ]]; then
    LAB_ROOT="$(cd "$LAB_ROOT" && pwd)" || fail "Failed to resolve lab root: $LAB_ROOT"
    info "Using provided lab root: $LAB_ROOT"
    return 0
  fi

  # Search for Elastic lab in common locations
  local candidates=("./elastic-lab" "$HOME/elastic-lab" "/home/*/elastic-lab" "/tmp/elastic-lab")
  for candidate in "${candidates[@]}"; do
    if [[ -d "$candidate" ]]; then
      LAB_ROOT="$(cd "$candidate" && pwd)" || fail "Failed to resolve lab root: $candidate"
      ok "Found Elastic lab at: $LAB_ROOT"
      return 0
    fi
  done

  fail "Could not find Elastic lab root. Please provide --lab-root PATH"
}

detect_elastic_stack() {
  section "2/8" "Detect Running Elastic Stack"

  if ! have_cmd docker; then
    fail "Docker not found. The Elastic stack must be running in Docker containers."
  fi

  local es_container
  es_container="$(docker ps -q --filter "name=elasticsearch" 2>/dev/null | head -1 || true)"

  if [[ -z "$es_container" ]]; then
    fail "No running Elasticsearch container found. Please start the Elastic stack first using setup-soc-lab.sh"
  fi

  ok "Found Elasticsearch container: $es_container"
}

load_credentials() {
  section "3/8" "Extract Credentials and Configuration"

  local env_file="$LAB_ROOT/.env"
  [[ -f "$env_file" ]] || fail "Elastic lab .env not found at $env_file. Has setup-soc-lab.sh been run?"

  # Parse .env file safely without sourcing (to avoid issues with values like ES_JAVA_OPTS)
  ELASTIC_USERNAME="elastic"
  ELASTIC_PASSWORD="$(grep '^ELASTIC_PASSWORD=' "$env_file" | cut -d'=' -f2 | tr -d '\r')"
  ES_HOST_BIND="$(grep '^ES_HOST_BIND=' "$env_file" | cut -d'=' -f2 | tr -d '\r')"
  CERT_DIR="$LAB_ROOT/certs"

  # Extract port from ES_HOST_BIND (format: 127.0.0.1:19200)
  if [[ -n "$ES_HOST_BIND" && "$ES_HOST_BIND" == *":"* ]]; then
    ES_HOST_PORT="${ES_HOST_BIND##*:}"
  else
    ES_HOST_PORT="9200"
  fi

  [[ -n "$ELASTIC_PASSWORD" ]] || fail "ELASTIC_PASSWORD not found in .env"
  
  # Verify certificate directory and file exist
  local ca_cert="$CERT_DIR/ca/ca.crt"
  [[ -d "$CERT_DIR/ca" ]] || fail "CA certificate directory not found at $CERT_DIR/ca"
  [[ -f "$ca_cert" ]] || fail "CA certificate file not found at $ca_cert"

  ok "Username: $ELASTIC_USERNAME"
  ok "Elasticsearch host: ${ES_HOST_BIND%:*}"
  ok "Elasticsearch port: $ES_HOST_PORT"
  ok "CA certificate: $ca_cert"
}

validate_connectivity() {
  section "4/8" "Validate Elasticsearch Connectivity"

  local ca_cert="$CERT_DIR/ca/ca.crt"
  local es_url="https://127.0.0.1:${ES_HOST_PORT}/_cluster/health"

  [[ -f "$ca_cert" ]] || fail "CA certificate not found at $ca_cert"

  info "Testing connection to Elasticsearch at $es_url..."
  info "Using credentials: $ELASTIC_USERNAME"
  info "Using certificate: $ca_cert"
  
  if curl -fsSL --cacert "$ca_cert" -u "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" "$es_url" >/dev/null 2>&1; then
    ok "Successfully connected to Elasticsearch"
  else
    warn "Connection attempt failed. Debugging information:"
    echo ""
    curl -v --cacert "$ca_cert" -u "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" "$es_url" 2>&1 | head -50 || true
    echo ""
    fail "Failed to connect to Elasticsearch. Verify credentials, port, and that the cluster is healthy."
  fi
}

ensure_packages() {
  section "5/8" "Install Dependencies"

  if ! have_cmd apt-get; then
    fail "apt-get not found. Manual Filebeat installation required for your distribution."
  fi

  info "Installing required packages..."
  apt-get update -y
  apt-get install -y curl apt-transport-https

  ok "Dependencies installed"
}

install_filebeat() {
  section "6/8" "Install Filebeat"

  if dpkg -l | grep -q "^ii.*filebeat"; then
    info "Filebeat already installed; checking version..."
    filebeat version 2>&1 | head -1 || true
  else
    info "Adding Elastic APT repository..."
    curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg
    sh -c 'echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/9.x/apt stable main" > /etc/apt/sources.list.d/elastic-9.x.list'
    apt-get update -y

    info "Installing Filebeat..."
    apt-get install -y filebeat
  fi

  ok "Filebeat ready"
}

setup_certificates() {
  section "7/8" "Setup SSL Certificates"

  info "Copying CA certificate to Filebeat config location..."
  mkdir -p /etc/filebeat/certs
  cp "$CERT_DIR/ca/ca.crt" /etc/filebeat/certs/ca.crt

  chmod 644 /etc/filebeat/certs/ca.crt
  ok "Certificates in place"
}

configure_filebeat() {
  info "Generating Filebeat configuration..."

  local config_file="/etc/filebeat/filebeat.yml"
  local lab_config="$LAB_ROOT/filebeat/filebeat.yml"

  # Backup existing config if present
  [[ -f "$config_file" ]] && cp "$config_file" "${config_file}.backup" && info "Backed up existing config to ${config_file}.backup"

  # Create the configuration with extracted credentials
  cat > "$config_file" <<EOF
# Generated by deploy-filebeat-agent.sh
# Real-time log forwarding to Elastic Stack lab environment

filebeat.inputs:
- type: log
  enabled: true
  paths:
    - /var/log/*.log
    - /var/log/**/*.log
  tail_files: true
  scan_frequency: 1s

- type: journald
  enabled: true

filebeat.config.modules:
  path: /usr/share/filebeat/modules.d/*.yml
  reload.enabled: false

output.elasticsearch:
  hosts: ["https://localhost:${ES_HOST_PORT}"]
  username: "${ELASTIC_USERNAME}"
  password: "${ELASTIC_PASSWORD}"
  protocol: https
  ssl.certificate_authorities: ["/etc/filebeat/certs/ca.crt"]

setup.template.enabled: true
setup.ilm.enabled: false

processors:
- add_host_metadata: ~
- add_cloud_metadata: ~

logging.level: info
logging.to_files: true
logging.files:
  path: /var/log/filebeat
  name: filebeat
  keepfiles: 7
  permissions: 0640
EOF

  # Also save a copy in the lab directory for reference
  mkdir -p "$LAB_ROOT/filebeat"
  cp "$config_file" "$lab_config"

  ok "Configuration written to $config_file"
  ok "Reference copy at $lab_config"
}

validate_filebeat_config() {
  info "Validating Filebeat configuration..."
  if filebeat test config -c /etc/filebeat/filebeat.yml >/dev/null 2>&1; then
    ok "Configuration is valid"
  else
    warn "Configuration validation failed:"
    filebeat test config -c /etc/filebeat/filebeat.yml 2>&1 | head -20 || true
    fail "Please check the configuration and try again."
  fi
}

start_filebeat() {
  info "Enabling and starting Filebeat service..."

  systemctl enable filebeat >/dev/null 2>&1
  if systemctl is-active --quiet filebeat; then
    systemctl restart filebeat
  else
    systemctl start filebeat
  fi

  # Wait for startup
  sleep 2

  if systemctl is-active --quiet filebeat; then
    ok "Filebeat service started successfully"
  else
    warn "Filebeat service failed to start. Diagnostic information:"
    echo ""
    systemctl status filebeat --no-pager || true
    echo ""
    info "Last 30 lines of Filebeat logs:"
    journalctl -u filebeat -n 30 --no-pager || tail -30 /var/log/filebeat/filebeat.log || true
    fail "Please review the logs above and ensure the Elasticsearch cluster is accessible."
  fi
}

verify_logs() {
  section "8/8" "Verify Log Forwarding"

  info "Checking Filebeat status..."
  systemctl status filebeat --no-pager || true

  info "Tailing Filebeat logs (last 20 lines)..."
  tail -20 /var/log/filebeat/filebeat.log 2>/dev/null || info "Log file not yet available"

  info "Checking data ingestion into Elasticsearch..."
  local doc_count
  doc_count=$(curl -fsS --cacert "$CERT_DIR/ca/ca.crt" \
    -u "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" \
    "https://localhost:${ES_HOST_PORT}/_cat/indices?format=json" 2>/dev/null | \
    grep -o '"docs.count":[0-9]*' | tail -1 | cut -d: -f2 || echo "0")

  if [[ "$doc_count" -gt 0 ]]; then
    ok "Logs detected in Elasticsearch ($doc_count documents)"
  else
    warn "No logs detected yet. Filebeat may still be initializing. Check again in a few moments."
  fi

  printf '\n%s%s[SUCCESS]%s Filebeat Agent Deployment Complete\n' "$C_GREEN" "$C_BOLD" "$C_RESET"
  cat <<EOF

Next Steps:
1. Verify logs in Kibana:
   - Open: http://localhost:5601
   - Go to: Stack Management > Index Patterns
   - Create an index pattern for "filebeat-*"
   - View logs in Discover tab

2. Monitor Filebeat:
   - Status:   systemctl status filebeat
   - Logs:     tail -f /var/log/filebeat/filebeat.log
   - Stop:     systemctl stop filebeat
   - Start:    systemctl start filebeat

3. Troubleshooting:
   - Check connectivity: curl -k -u elastic:PASS https://localhost:9200/_cluster/health
   - Reload config:     sudo systemctl reload filebeat
   - Full restart:      sudo systemctl restart filebeat

Configuration Reference:
   - Main config: /etc/filebeat/filebeat.yml
   - Lab backup:  $LAB_ROOT/filebeat/filebeat.yml
   - Logs:        /var/log/filebeat/filebeat.log

EOF
}

main() {
  parse_args "$@"

  is_root || fail "This script must be run with sudo."
  validate_linux
  find_lab_root
  detect_elastic_stack
  load_credentials
  validate_connectivity
  ensure_packages
  install_filebeat
  setup_certificates
  configure_filebeat
  validate_filebeat_config
  start_filebeat
  verify_logs

  ok "Filebeat agent successfully deployed and forwarding logs to Elasticsearch."
}

main "$@"
