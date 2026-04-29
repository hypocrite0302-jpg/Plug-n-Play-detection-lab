#!/bin/bash

set -e
set -o pipefail

ELASTIC_VERSION="8.12.2"
LAB="soc-lab"
DEFAULT_USER="default"
FILEBEAT_DEB="filebeat-${ELASTIC_VERSION}-amd64.deb"
ATOMIC_DIR="$HOME/atomic-red-team"
DEFAULT_KIBANA_LOGIN_USERNAME="soc_admin"
ELASTIC_USERNAME="elastic"
KIBANA_SYSTEM_USERNAME="kibana_system"
CREDENTIALS_FILE=""
FILEBEAT_STREAM_PATTERN="filebeat-*"
WSL_RETRO_MARKER_FILE=""

C_RESET="$(printf '\033[0m')"
C_BOLD="$(printf '\033[1m')"
C_BLUE="$(printf '\033[38;5;45m')"
C_CYAN="$(printf '\033[38;5;81m')"
C_GOLD="$(printf '\033[38;5;221m')"
C_GREEN="$(printf '\033[38;5;84m')"
C_RED="$(printf '\033[38;5;203m')"
C_SLATE="$(printf '\033[38;5;110m')"

info() { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$1"; }
ok() { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
warn() { printf '%s[WARN]%s %s\n' "$C_GOLD" "$C_RESET" "$1"; }
phase() { printf '\n%s%s[%s]%s %s\n' "$C_BOLD" "$C_CYAN" "$1" "$C_RESET" "$2"; }

render_banner() {
cat <<EOF

${C_BOLD}${C_CYAN}╔════════════════════════════════════════════════════════════════════╗${C_RESET}
${C_BOLD}${C_CYAN}║${C_RESET} ${C_BOLD}${C_GOLD}Neon Foundry${C_RESET} ${C_SLATE}::${C_RESET} Elastic Detection Engineering SOC Lab               ${C_BOLD}${C_CYAN}║${C_RESET}
${C_BOLD}${C_CYAN}║${C_RESET} ${C_SLATE}WSL-friendly bootstrap for telemetry, search, and detection work${C_RESET} ${C_BOLD}${C_CYAN}║${C_RESET}
${C_BOLD}${C_CYAN}╚════════════════════════════════════════════════════════════════════╝${C_RESET}

EOF
}

command_exists() {
command -v "$1" >/dev/null 2>&1
}

is_wsl() {
grep -qi microsoft /proc/version 2>/dev/null
}

generate_secret() {
local LENGTH="${1:-24}"
python3 - "$LENGTH" <<'PY'
import secrets
import string
import sys

length = int(sys.argv[1])
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(length)))
PY
}

yaml_quote() {
python3 - "$1" <<'PY'
import json
import sys

print(json.dumps(sys.argv[1]))
PY
}

installed_filebeat_version() {
dpkg-query -W -f='${Version}\n' filebeat 2>/dev/null || true
}

filebeat_version_matches_stack() {
local INSTALLED_VERSION="$1"
[ -n "$INSTALLED_VERSION" ] && [[ "$INSTALLED_VERSION" == "${ELASTIC_VERSION}"* ]]
}

prepare_wsl_retro_ingest() {
if ! is_wsl; then
return 0
fi

if [ -f "$WSL_RETRO_MARKER_FILE" ]; then
info "WSL retrospective Filebeat backfill already completed on a previous run"
return 0
fi

info "Preparing one-time retrospective Filebeat backfill for WSL host logs"

if command_exists systemctl; then
sudo systemctl stop filebeat >/dev/null 2>&1 || true
else
sudo service filebeat stop >/dev/null 2>&1 || true
fi

sudo rm -rf /var/lib/filebeat/registry /var/lib/filebeat/meta.json
}

mark_wsl_retro_ingest_complete() {
if ! is_wsl; then
return 0
fi

touch "$WSL_RETRO_MARKER_FILE"
ok "WSL retrospective Filebeat backfill marker written"
}

wait_for_filebeat_data() {
local ATTEMPTS="${1:-18}"

info "Verifying Filebeat ingestion into Elasticsearch..."

if command_exists logger; then
logger -t soc-lab "filebeat validation event $(date -Iseconds)" >/dev/null 2>&1 || true
fi

for ((i=1; i<=ATTEMPTS; i++)); do
if curl -fsS -u "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" "http://localhost:9200/_data_stream/${FILEBEAT_STREAM_PATTERN}" 2>/dev/null | jq -e '.data_streams | length > 0' >/dev/null 2>&1; then
ok "Filebeat data streams detected"
return 0
fi

if curl -fsS -u "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" "http://localhost:9200/_cat/indices/${FILEBEAT_STREAM_PATTERN}?format=json" 2>/dev/null | jq -e 'length > 0' >/dev/null 2>&1; then
ok "Filebeat indices detected"
return 0
fi

sleep 5
done

error_exit "
Filebeat started but no filebeat-* indices or data streams appeared.

Fix:
sudo filebeat test output -e
sudo filebeat setup -e
sudo journalctl -u filebeat -n 120 --no-pager
curl -u ${ELASTIC_USERNAME}:PASSWORD http://localhost:9200/_data_stream/${FILEBEAT_STREAM_PATTERN}
"
}

valid_kibana_login_username() {
local VALUE="$1"

[[ "$VALUE" =~ ^[A-Za-z][A-Za-z0-9._-]{2,31}$ ]] || return 1

case "$VALUE" in
elastic|kibana_system|beats_system|logstash_system|apm_system|remote_monitoring_user)
return 1
;;
esac

return 0
}

load_lab_credentials() {
if [ -f "$CREDENTIALS_FILE" ]; then
set -a
. "$CREDENTIALS_FILE"
set +a
fi
}

credentials_complete() {
[ -n "${ELASTIC_PASSWORD:-}" ] && \
[ -n "${KIBANA_SYSTEM_PASSWORD:-}" ] && \
[ -n "${KIBANA_LOGIN_USERNAME:-}" ] && \
[ -n "${KIBANA_LOGIN_PASSWORD:-}" ]
}

persist_lab_credentials() {
umask 077
{
printf 'ELASTIC_PASSWORD=%q\n' "$ELASTIC_PASSWORD"
printf 'KIBANA_SYSTEM_PASSWORD=%q\n' "$KIBANA_SYSTEM_PASSWORD"
printf 'KIBANA_LOGIN_USERNAME=%q\n' "$KIBANA_LOGIN_USERNAME"
printf 'KIBANA_LOGIN_PASSWORD=%q\n' "$KIBANA_LOGIN_PASSWORD"
} > "$CREDENTIALS_FILE"
}

prompt_kibana_login_credentials() {
local INPUT_USERNAME
local INPUT_PASSWORD
local CONFIRM_PASSWORD

while true; do
read -r -p "Kibana login username [${DEFAULT_KIBANA_LOGIN_USERNAME}]: " INPUT_USERNAME
INPUT_USERNAME="${INPUT_USERNAME:-$DEFAULT_KIBANA_LOGIN_USERNAME}"

if valid_kibana_login_username "$INPUT_USERNAME"; then
KIBANA_LOGIN_USERNAME="$INPUT_USERNAME"
break
fi

echo "[WARN] Username must be 3-32 characters, start with a letter, and avoid reserved Elastic usernames."
done

while true; do
read -r -s -p "Kibana login password [leave blank to auto-generate]: " INPUT_PASSWORD
echo

if [ -z "$INPUT_PASSWORD" ]; then
KIBANA_LOGIN_PASSWORD="$(generate_secret 24)"
echo "[INFO] Generated a secure Kibana login password automatically."
break
fi

read -r -s -p "Confirm Kibana login password: " CONFIRM_PASSWORD
echo

if [ "$INPUT_PASSWORD" = "$CONFIRM_PASSWORD" ]; then
KIBANA_LOGIN_PASSWORD="$INPUT_PASSWORD"
break
fi

echo "[WARN] Passwords did not match. Please try again."
done
}

configure_lab_credentials() {
load_lab_credentials

if credentials_complete; then
echo "[INFO] Reusing saved Elastic and Kibana credentials from $CREDENTIALS_FILE"
return 0
fi

echo "[INFO] Configuring Elastic and Kibana credentials..."

ELASTIC_PASSWORD="$(generate_secret 24)"
KIBANA_SYSTEM_PASSWORD="$(generate_secret 24)"

if [ -t 0 ]; then
prompt_kibana_login_credentials
else
KIBANA_LOGIN_USERNAME="$DEFAULT_KIBANA_LOGIN_USERNAME"
KIBANA_LOGIN_PASSWORD="$(generate_secret 24)"
echo "[INFO] Non-interactive shell detected. Generated Kibana login credentials automatically."
fi

persist_lab_credentials
echo "[OK] Credentials saved to $CREDENTIALS_FILE"
}

elastic_api() {
local METHOD="$1"
local ENDPOINT="$2"
local DATA="${3:-}"

if [ -n "$DATA" ]; then
curl -fsS -u "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" \
  -H "Content-Type: application/json" \
  -X "$METHOD" \
  "http://localhost:9200${ENDPOINT}" \
  -d "$DATA"
else
curl -fsS -u "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}" \
  -X "$METHOD" \
  "http://localhost:9200${ENDPOINT}"
fi
}

bootstrap_kibana_security() {
local KIBANA_SYSTEM_PAYLOAD
local KIBANA_LOGIN_PAYLOAD

echo "[INFO] Configuring Kibana service credentials..."

KIBANA_SYSTEM_PAYLOAD="$(jq -n --arg password "$KIBANA_SYSTEM_PASSWORD" '{password: $password}')"
elastic_api POST "/_security/user/${KIBANA_SYSTEM_USERNAME}/_password" "$KIBANA_SYSTEM_PAYLOAD" >/dev/null

KIBANA_LOGIN_PAYLOAD="$(jq -n \
  --arg password "$KIBANA_LOGIN_PASSWORD" \
  '{password: $password, roles: ["superuser"], full_name: "SOC Lab Administrator"}')"
elastic_api POST "/_security/user/${KIBANA_LOGIN_USERNAME}" "$KIBANA_LOGIN_PAYLOAD" >/dev/null

echo "[OK] Kibana credentials configured"
}

write_standard_filebeat_config() {
local ELASTIC_USERNAME_YAML
local ELASTIC_PASSWORD_YAML

ELASTIC_USERNAME_YAML="$(yaml_quote "$ELASTIC_USERNAME")"
ELASTIC_PASSWORD_YAML="$(yaml_quote "$ELASTIC_PASSWORD")"

sudo tee /etc/filebeat/filebeat.yml > /dev/null <<EOF
filebeat.inputs:

- type: filestream
  id: host-system-logs
  enabled: true
  paths:
    - /var/log/syslog
    - /var/log/auth.log
  ignore_older: 0

output.elasticsearch:
  hosts: ["http://localhost:9200"]
  username: ${ELASTIC_USERNAME_YAML}
  password: ${ELASTIC_PASSWORD_YAML}

setup.kibana:
  host: "localhost:5601"
  username: ${ELASTIC_USERNAME_YAML}
  password: ${ELASTIC_PASSWORD_YAML}
EOF
}

write_wsl_filebeat_config() {
local ELASTIC_USERNAME_YAML
local ELASTIC_PASSWORD_YAML

ELASTIC_USERNAME_YAML="$(yaml_quote "$ELASTIC_USERNAME")"
ELASTIC_PASSWORD_YAML="$(yaml_quote "$ELASTIC_PASSWORD")"

sudo tee /etc/filebeat/filebeat.yml > /dev/null <<EOF
filebeat.inputs:

- type: filestream
  id: wsl-host-logs
  enabled: true
  paths:
    - /var/log/*.log
    - /var/log/*/*.log
    - /var/log/dpkg.log
    - /var/log/apt/history.log
    - /var/log/apt/term.log
    - /var/log/unattended-upgrades/*.log
  fields:
    telemetry_source: wsl-host-logs
  fields_under_root: true
  ignore_older: 0

- type: filestream
  id: wsl-bash-history
  enabled: true
  paths:
    - /home/*/.bash_history
    - /root/.bash_history
  prospector.scanner.check_interval: 10s
  fields:
    telemetry_source: bash_history
  fields_under_root: true
  ignore_older: 0

- type: filestream
  id: wsl-docker-container-logs
  enabled: true
  paths:
    - /var/lib/docker/containers/*/*.log
  parsers:
    - ndjson:
        target: docker
        add_error_key: true
  fields:
    telemetry_source: docker-json-logs
  fields_under_root: true
  ignore_older: 0

output.elasticsearch:
  hosts: ["http://localhost:9200"]
  username: ${ELASTIC_USERNAME_YAML}
  password: ${ELASTIC_PASSWORD_YAML}

setup.kibana:
  host: "localhost:5601"
  username: ${ELASTIC_USERNAME_YAML}
  password: ${ELASTIC_PASSWORD_YAML}
EOF
}

configure_wsl_history_capture() {
echo "[INFO] Configuring WSL shell history telemetry..."

sudo tee /etc/profile.d/soc-lab-history-sync.sh > /dev/null <<'EOF'
# Flush interactive bash history after each prompt so Filebeat can ingest it promptly on WSL.
case "${BASH_VERSION:-}" in
  "") return 0 2>/dev/null || exit 0 ;;
esac

case $- in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

shopt -s histappend 2>/dev/null || true
export HISTSIZE="${HISTSIZE:-50000}"
export HISTFILESIZE="${HISTFILESIZE:-100000}"

case "${PROMPT_COMMAND:-}" in
  *"history -a; history -n"*) ;;
  "")
    export PROMPT_COMMAND="history -a; history -n"
    ;;
  *)
    export PROMPT_COMMAND="history -a; history -n; ${PROMPT_COMMAND}"
    ;;
esac
EOF

echo "[OK] WSL shell history telemetry configured"
}

start_service() {
local SERVICE_NAME="$1"

if command_exists systemctl && sudo systemctl start "$SERVICE_NAME" >/dev/null 2>&1; then
return 0
fi

if command_exists service && sudo service "$SERVICE_NAME" start >/dev/null 2>&1; then
return 0
fi

error_exit "
Unable to start service: $SERVICE_NAME

Fix:
If using systemd:
sudo systemctl start $SERVICE_NAME

If using WSL without systemd:
sudo service $SERVICE_NAME start
"
}

enable_service() {
local SERVICE_NAME="$1"

if command_exists systemctl && sudo systemctl enable "$SERVICE_NAME" >/dev/null 2>&1; then
return 0
fi

if command_exists update-rc.d && sudo update-rc.d "$SERVICE_NAME" defaults >/dev/null 2>&1; then
return 0
fi

echo "[INFO] Skipping persistent enable for $SERVICE_NAME"
}

restart_service() {
local SERVICE_NAME="$1"

if command_exists systemctl && sudo systemctl restart "$SERVICE_NAME" >/dev/null 2>&1; then
return 0
fi

if command_exists service && sudo service "$SERVICE_NAME" restart >/dev/null 2>&1; then
return 0
fi

error_exit "
Unable to restart service: $SERVICE_NAME

Fix:
If using systemd:
sudo systemctl restart $SERVICE_NAME

If using WSL without systemd:
sudo service $SERVICE_NAME restart
"
}

wait_for_http() {
local SERVICE_NAME="$1"
local URL="$2"
local ATTEMPTS="${3:-30}"
shift 3

echo "[INFO] Waiting for $SERVICE_NAME..."

for ((i=1; i<=ATTEMPTS; i++)); do
if curl -fsS "$@" "$URL" >/dev/null 2>&1; then
echo "[OK] $SERVICE_NAME is responding"
return 0
fi

sleep 5
done

error_exit "
$SERVICE_NAME did not become ready in time.

Fix:
docker ps
docker logs ${SERVICE_NAME,,}
"
}

#############################
# ERROR HANDLER
#############################

error_exit() {

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf '%s[ERROR]%s Installation failed.\n' "$C_RED" "$C_RESET"
echo
echo "Possible Fix:"
echo "$1"
echo
echo "If the issue persists run:"
echo "docker ps"
echo "docker logs elasticsearch"
echo
echo "Then re-run the installer."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
exit 1
}

trap 'error_exit "A command failed unexpectedly. Ensure Docker is running and ports are free."' ERR

#############################
# STYLISH BANNER
#############################

if [ -t 1 ] && command_exists clear; then
clear
fi

render_banner
info "Initializing SOC Lab Setup"
sleep 2

##################################
# CREATE DEFAULT USER
##################################

phase "1/9" "Baseline Host Preparation"

if id "$DEFAULT_USER" &>/dev/null; then
info "User '$DEFAULT_USER' already exists"
else

info "Creating default user..."

sudo useradd -m -s /bin/bash "$DEFAULT_USER" || error_exit "User creation failed."

echo "${DEFAULT_USER}:${DEFAULT_USER}" | sudo chpasswd

sudo usermod -aG sudo "$DEFAULT_USER"

ok "Default user created"

fi

##################################
# CHECK INTERNET
##################################

info "Checking internet connectivity..."

if command_exists curl; then
curl -fsSL --max-time 10 https://artifacts.elastic.co >/dev/null 2>&1 || error_exit "
Internet connectivity failed.

Fix:
Check network connectivity
Ensure DNS resolution works

Test manually:
curl -I https://artifacts.elastic.co
"
else
getent hosts artifacts.elastic.co >/dev/null 2>&1 || error_exit "
Internet connectivity failed.

Fix:
Check network connectivity
Ensure DNS resolution works

Test manually:
getent hosts artifacts.elastic.co
"
fi

ok "Internet working"

##################################
# INSTALL DEPENDENCIES
##################################

info "Installing system dependencies..."

sudo apt update || error_exit "
APT update failed.

Fix:
sudo rm -rf /var/lib/apt/lists/*
sudo apt update
"

sudo apt install -y \
curl \
jq \
git \
python3 \
python3-pip \
python3-venv \
auditd \
apt-transport-https \
ca-certificates \
gnupg \
lsb-release \
lsof \
pipx || error_exit "
Package installation failed.

Fix:
sudo dpkg --configure -a
sudo apt --fix-broken install
"

ok "Dependencies installed"

##################################
# CHECK PORTS
##################################

PORTS=(9200 5601 8220)

phase "2/9" "Dependency And Port Validation"
info "Checking required ports..."

for PORT in "${PORTS[@]}"; do

if sudo lsof -i:"$PORT" >/dev/null 2>&1 ; then

error_exit "
Port $PORT is already in use.

Fix:

Find conflicting service:
sudo lsof -i:$PORT

Stop service:
sudo kill -9 PID

OR stop container:
docker stop container_id
"

fi

done

ok "Ports available"

##################################
# INSTALL DOCKER
##################################

phase "3/9" "Docker Engine Preparation"

if command -v docker &>/dev/null; then
info "Docker already installed"
else

info "Installing Docker..."

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
sudo gpg --dearmor -o /usr/share/keyrings/docker.gpg

echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(lsb_release -cs) stable" | \
sudo tee /etc/apt/sources.list.d/docker.list

sudo apt update

sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

start_service docker

fi

if ! getent group docker >/dev/null 2>&1; then
sudo groupadd docker >/dev/null 2>&1 || true
fi

for GROUP_USER in "$USER" "$DEFAULT_USER"; do
if id "$GROUP_USER" >/dev/null 2>&1; then
sudo usermod -aG docker "$GROUP_USER"
fi
done

sudo docker info >/dev/null 2>&1 || error_exit "
Docker daemon not running.

Fix:

If using Docker Desktop:
Start Docker Desktop.

If using Linux:
sudo systemctl start docker
"

ok "Docker ready"
info "Docker group membership updated for '$USER' and '$DEFAULT_USER'"

##################################
# LAB DIRECTORY
##################################

phase "4/9" "Credential Forge"

mkdir -p ~/$LAB
cd ~/$LAB

CREDENTIALS_FILE="$PWD/.credentials.env"
WSL_RETRO_MARKER_FILE="$PWD/.wsl-retro-ingest-complete"
configure_lab_credentials

##################################
# CREATE ELASTIC STACK
##################################

phase "5/9" "Elastic Stack Assembly"
info "Writing docker compose..."

ELASTIC_PASSWORD_YAML="$(yaml_quote "$ELASTIC_PASSWORD")"
KIBANA_SYSTEM_USERNAME_YAML="$(yaml_quote "$KIBANA_SYSTEM_USERNAME")"
KIBANA_SYSTEM_PASSWORD_YAML="$(yaml_quote "$KIBANA_SYSTEM_PASSWORD")"
ELASTIC_USERNAME_YAML="$(yaml_quote "$ELASTIC_USERNAME")"

cat > docker-compose.yml << EOF
services:

  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:${ELASTIC_VERSION}
    container_name: elasticsearch
    environment:
      discovery.type: "single-node"
      xpack.security.enabled: "true"
      ELASTIC_PASSWORD: ${ELASTIC_PASSWORD_YAML}
      ES_JAVA_OPTS: "-Xms1g -Xmx1g"
    ports:
      - "9200:9200"
    volumes:
      - esdata:/usr/share/elasticsearch/data
    restart: unless-stopped

  kibana:
    image: docker.elastic.co/kibana/kibana:${ELASTIC_VERSION}
    container_name: kibana
    environment:
      ELASTICSEARCH_HOSTS: "http://elasticsearch:9200"
      ELASTICSEARCH_USERNAME: ${KIBANA_SYSTEM_USERNAME_YAML}
      ELASTICSEARCH_PASSWORD: ${KIBANA_SYSTEM_PASSWORD_YAML}
      xpack.encryptedSavedObjects.encryptionKey: "76b5beec9f6b14e2752f3342e6676b53199ff16feae0e760e1d6cf160581f8d0"
    ports:
      - "5601:5601"
    depends_on:
      - elasticsearch
    restart: unless-stopped

  fleet-server:
    image: docker.elastic.co/beats/elastic-agent:${ELASTIC_VERSION}
    container_name: fleet-server
    environment:
      FLEET_SERVER_ENABLE: "1"
      FLEET_SERVER_ELASTICSEARCH_HOST: "http://elasticsearch:9200"
      FLEET_SERVER_ELASTICSEARCH_USERNAME: ${ELASTIC_USERNAME_YAML}
      FLEET_SERVER_ELASTICSEARCH_PASSWORD: ${ELASTIC_PASSWORD_YAML}
      KIBANA_FLEET_SETUP: "1"
      KIBANA_HOST: "http://kibana:5601"
      KIBANA_USERNAME: ${ELASTIC_USERNAME_YAML}
      KIBANA_PASSWORD: ${ELASTIC_PASSWORD_YAML}
      FLEET_SERVER_INSECURE_HTTP: "1"
    ports:
      - "8220:8220"
    depends_on:
      - elasticsearch
      - kibana
    restart: unless-stopped

volumes:
  esdata:
EOF

ok "Docker compose created"

##################################
# START STACK
##################################

phase "6/9" "Secure Bootstrap"
info "Starting Elastic stack..."

sudo docker compose pull || error_exit "
Image pull failed.

Fix:
Check internet connectivity.
Try manually:
docker pull docker.elastic.co/elasticsearch/elasticsearch:${ELASTIC_VERSION}
"

sudo docker compose up -d elasticsearch || error_exit "
Container startup failed.

Fix:
docker logs elasticsearch
docker logs kibana
"

ok "Elasticsearch container started"

wait_for_http "Elasticsearch" "http://localhost:9200" 24 -u "${ELASTIC_USERNAME}:${ELASTIC_PASSWORD}"
bootstrap_kibana_security

sudo docker compose up -d kibana fleet-server || error_exit "
Container startup failed.

Fix:
docker logs elasticsearch
docker logs kibana
docker logs fleet-server
"

ok "Kibana and Fleet Server containers started"

wait_for_http "Kibana" "http://localhost:5601/api/status" 60 -u "${KIBANA_LOGIN_USERNAME}:${KIBANA_LOGIN_PASSWORD}"

##################################
# FILEBEAT
##################################

phase "7/9" "Telemetry Pipeline"
info "Installing Filebeat..."

INSTALLED_FILEBEAT_VERSION="$(installed_filebeat_version)"

if filebeat_version_matches_stack "$INSTALLED_FILEBEAT_VERSION"; then
info "Filebeat ${INSTALLED_FILEBEAT_VERSION} already installed"
else
if [ -n "$INSTALLED_FILEBEAT_VERSION" ]; then
warn "Filebeat ${INSTALLED_FILEBEAT_VERSION} does not match Elastic ${ELASTIC_VERSION}. Reinstalling the matching version."
if command_exists systemctl; then
sudo systemctl stop filebeat >/dev/null 2>&1 || true
else
sudo service filebeat stop >/dev/null 2>&1 || true
fi
sudo apt-get purge -y filebeat >/dev/null 2>&1 || sudo dpkg -r filebeat >/dev/null 2>&1 || true
sudo rm -rf /etc/filebeat /var/lib/filebeat
fi

curl -fsSL -o "$FILEBEAT_DEB" "https://artifacts.elastic.co/downloads/beats/filebeat/$FILEBEAT_DEB" || error_exit "
Filebeat download failed.

Fix:
curl -I https://artifacts.elastic.co/downloads/beats/filebeat/$FILEBEAT_DEB
"

sudo dpkg -i "$FILEBEAT_DEB" || sudo apt-get install -f -y || error_exit "
Filebeat installation failed.

Fix:
sudo apt-get install -f
sudo dpkg -i $FILEBEAT_DEB
"
fi

##################################
# CONFIGURE FILEBEAT
##################################

info "Configuring Filebeat..."

if is_wsl; then
write_wsl_filebeat_config
configure_wsl_history_capture
prepare_wsl_retro_ingest
else
write_standard_filebeat_config
fi

if ! sudo filebeat modules enable system >/dev/null 2>&1; then
info "Filebeat system module may already be enabled"
fi

sudo filebeat test config -e >/dev/null 2>&1 || error_exit "
Filebeat configuration validation failed.

Fix:
sudo filebeat test config -e
sudo cat /etc/filebeat/filebeat.yml
"

sudo filebeat test output -e >/dev/null 2>&1 || error_exit "
Filebeat could not authenticate or connect to Elasticsearch.

Fix:
sudo filebeat test output -e
curl -u ${ELASTIC_USERNAME}:PASSWORD http://localhost:9200
"

sudo filebeat setup -e >/dev/null 2>&1 || error_exit "
Filebeat setup failed while loading templates or Kibana assets.

Fix:
sudo filebeat setup -e
curl -u ${ELASTIC_USERNAME}:PASSWORD http://localhost:9200/_cat/indices/filebeat-*?v
"

restart_service filebeat
enable_service filebeat

ok "Filebeat running"
wait_for_filebeat_data
mark_wsl_retro_ingest_complete

##################################
# AUDITD TELEMETRY
##################################

phase "8/9" "Host Telemetry Enrichment"
info "Enabling process telemetry..."

if is_wsl; then
warn "WSL detected. Skipping auditd process telemetry because the Linux audit subsystem is not reliably available in WSL."
elif ! command_exists auditctl; then
warn "auditctl not found. Skipping process telemetry enablement."
elif sudo auditctl -l >/dev/null 2>&1; then
if sudo auditctl -l | grep -q "exec_log"; then
info "Process telemetry rule already enabled"
elif sudo auditctl -a always,exit -F arch=b64 -S execve -k exec_log >/dev/null 2>&1; then
ok "Process telemetry enabled"
else
warn "Unable to add the auditd exec_log rule. Continuing without host process telemetry."
fi
else
warn "auditctl is present but not permitted in this environment. Continuing without host process telemetry."
fi

##################################
# INSTALL ATOMIC RED TEAM
##################################

phase "9/9" "Detection Tooling Payloads"
info "Installing Atomic Red Team..."

if [ -d "$ATOMIC_DIR/.git" ]; then
git -C "$ATOMIC_DIR" pull --ff-only
else
git clone https://github.com/redcanaryco/atomic-red-team.git "$ATOMIC_DIR"
fi

##################################
# INSTALL SIGMA
##################################

info "Installing Sigma CLI..."

export PATH="$HOME/.local/bin:$PATH"
pipx ensurepath >/dev/null 2>&1 || true

if pipx list 2>/dev/null | grep -q "package sigma-cli "; then
pipx upgrade sigma-cli
else
pipx install sigma-cli
fi

##################################
# FINISHED
##################################

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf '%s[SUCCESS]%s SOC LAB INSTALL COMPLETE\n' "$C_GREEN" "$C_RESET"
echo
echo "Kibana:"
echo "http://localhost:5601"
echo
echo "Elasticsearch:"
echo "http://localhost:9200"
echo
echo "Kibana Login:"
echo "username: ${KIBANA_LOGIN_USERNAME}"
echo "password: ${KIBANA_LOGIN_PASSWORD}"
echo
echo "Elastic Superuser:"
echo "username: ${ELASTIC_USERNAME}"
echo "password: ${ELASTIC_PASSWORD}"
echo
echo "Credential File:"
echo "$CREDENTIALS_FILE"
echo
echo "Linux Helper User:"
echo "username: default"
echo "password: default"
echo
echo "Happy Detection Engineering."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
