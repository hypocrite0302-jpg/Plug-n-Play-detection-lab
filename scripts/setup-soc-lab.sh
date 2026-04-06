#!/bin/bash

set -e
set -o pipefail

ELASTIC_VERSION="8.12.2"
LAB="soc-lab"
DEFAULT_USER="default"
FILEBEAT_DEB="filebeat-${ELASTIC_VERSION}-amd64.deb"
ATOMIC_DIR="$HOME/atomic-red-team"

command_exists() {
command -v "$1" >/dev/null 2>&1
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

echo "[INFO] Waiting for $SERVICE_NAME..."

for ((i=1; i<=ATTEMPTS; i++)); do
if curl -fsS "$URL" >/dev/null 2>&1; then
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

ensure_container_name_available() {
local CONTAINER_NAME="$1"
local EXPECTED_IMAGE="$2"
local CONTAINER_ID
local CONTAINER_IMAGE

CONTAINER_ID="$(sudo docker ps -aq -f "name=^/${CONTAINER_NAME}$" 2>/dev/null || true)"

if [ -z "$CONTAINER_ID" ]; then
return 0
fi

CONTAINER_IMAGE="$(sudo docker inspect -f '{{.Config.Image}}' "$CONTAINER_ID" 2>/dev/null || true)"

if [ "$CONTAINER_IMAGE" = "$EXPECTED_IMAGE" ]; then
echo "[INFO] Removing stale lab container '$CONTAINER_NAME'..."
sudo docker rm -f "$CONTAINER_ID" >/dev/null || error_exit "
Failed to remove stale container: $CONTAINER_NAME

Fix:
docker rm -f $CONTAINER_NAME
"
return 0
fi

error_exit "
Container name conflict detected for '$CONTAINER_NAME'.

Existing container image:
$CONTAINER_IMAGE

Fix:
Rename or remove the conflicting container:
docker rm -f $CONTAINER_NAME

Then re-run the installer.
"
}

cleanup_stale_lab_containers() {
echo "[INFO] Checking for stale lab containers..."

ensure_container_name_available "elasticsearch" "docker.elastic.co/elasticsearch/elasticsearch:${ELASTIC_VERSION}"
ensure_container_name_available "kibana" "docker.elastic.co/kibana/kibana:${ELASTIC_VERSION}"
ensure_container_name_available "fleet-server" "docker.elastic.co/beats/elastic-agent:${ELASTIC_VERSION}"

echo "[OK] Container names available"
}

#############################
# ERROR HANDLER
#############################

error_exit() {

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[ERROR] Installation failed."
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

cat << "EOF"

██╗   ██╗██╗  ████████╗██╗███╗   ███╗ █████╗ ████████╗███████╗
██║   ██║██║  ╚══██╔══╝██║████╗ ████║██╔══██╗╚══██╔══╝██╔════╝
██║   ██║██║     ██║   ██║██╔████╔██║███████║   ██║   █████╗
██║   ██║██║     ██║   ██║██║╚██╔╝██║██╔══██║   ██║   ██╔══╝
╚██████╔╝███████╗██║   ██║██║ ╚═╝ ██║██║  ██║   ██║   ███████╗
 ╚═════╝ ╚══════╝╚═╝   ╚═╝╚═╝     ╚═╝╚═╝  ╚═╝   ╚═╝   ╚══════╝

     ELASTIC DETECTION ENGINEERING SOC LAB
      Telemetry • Atomic Red Team • Sigma

EOF

echo "[INFO] Initializing SOC Lab Setup"
sleep 2

##################################
# CREATE DEFAULT USER
##################################

if id "$DEFAULT_USER" &>/dev/null; then
echo "[INFO] User '$DEFAULT_USER' already exists"
else

echo "[INFO] Creating default user..."

sudo useradd -m -s /bin/bash "$DEFAULT_USER" || error_exit "User creation failed."

echo "${DEFAULT_USER}:${DEFAULT_USER}" | sudo chpasswd

sudo usermod -aG sudo "$DEFAULT_USER"

echo "[OK] Default user created"

fi

##################################
# CHECK INTERNET
##################################

echo "[INFO] Checking internet connectivity..."

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

echo "[OK] Internet working"

##################################
# INSTALL DEPENDENCIES
##################################

echo "[INFO] Installing system dependencies..."

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

echo "[OK] Dependencies installed"

##################################
# CHECK PORTS
##################################

PORTS=(9200 5601 8220)

echo "[INFO] Checking required ports..."

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

echo "[OK] Ports available"

##################################
# INSTALL DOCKER
##################################

if command -v docker &>/dev/null; then
echo "[INFO] Docker already installed"
else

echo "[INFO] Installing Docker..."

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

echo "[OK] Docker ready"
echo "[INFO] Docker group membership updated for '$USER' and '$DEFAULT_USER'"

##################################
# LAB DIRECTORY
##################################

mkdir -p ~/$LAB
cd ~/$LAB

##################################
# CREATE ELASTIC STACK
##################################

echo "[INFO] Writing docker compose..."

cat > docker-compose.yml << EOF
services:

 elasticsearch:
  image: docker.elastic.co/elasticsearch/elasticsearch:${ELASTIC_VERSION}
  container_name: elasticsearch
  environment:
   - discovery.type=single-node
   - xpack.security.enabled=false
   - ES_JAVA_OPTS=-Xms1g -Xmx1g
  ports:
   - "9200:9200"
  volumes:
   - esdata:/usr/share/elasticsearch/data
  restart: unless-stopped

 kibana:
  image: docker.elastic.co/kibana/kibana:${ELASTIC_VERSION}
  container_name: kibana
  environment:
   - ELASTICSEARCH_HOSTS=http://elasticsearch:9200
   - xpack.encryptedSavedObjects.encryptionKey=76b5beec9f6b14e2752f3342e6676b53199ff16feae0e760e1d6cf160581f8d0
  ports:
   - "5601:5601"
  depends_on:
   - elasticsearch
  restart: unless-stopped

 fleet-server:
  image: docker.elastic.co/beats/elastic-agent:${ELASTIC_VERSION}
  container_name: fleet-server
  environment:
   - FLEET_SERVER_ENABLE=1
   - FLEET_SERVER_ELASTICSEARCH_HOST=http://elasticsearch:9200
   - FLEET_SERVER_INSECURE_HTTP=1
  ports:
   - "8220:8220"
  depends_on:
   - elasticsearch
   - kibana
  restart: unless-stopped

volumes:
 esdata:
EOF

echo "[OK] Docker compose created"

##################################
# START STACK
##################################

echo "[INFO] Starting Elastic stack..."

cleanup_stale_lab_containers

sudo docker compose down --remove-orphans >/dev/null 2>&1 || true

sudo docker compose pull || error_exit "
Image pull failed.

Fix:
Check internet connectivity.
Try manually:
docker pull docker.elastic.co/elasticsearch/elasticsearch:${ELASTIC_VERSION}
"

sudo docker compose up -d || error_exit "
Container startup failed.

Fix:
docker logs elasticsearch
docker logs kibana
"

echo "[OK] Elastic stack started"

wait_for_http "Elasticsearch" "http://localhost:9200" 24
wait_for_http "Kibana" "http://localhost:5601" 60

##################################
# FILEBEAT
##################################

echo "[INFO] Installing Filebeat..."

if dpkg -s filebeat >/dev/null 2>&1; then
echo "[INFO] Filebeat already installed"
else
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

echo "[INFO] Configuring Filebeat..."

sudo tee /etc/filebeat/filebeat.yml > /dev/null <<EOF
filebeat.inputs:

- type: log
  enabled: true
  paths:
    - /var/log/syslog
    - /var/log/auth.log

output.elasticsearch:
  hosts: ["http://localhost:9200"]

setup.kibana:
  host: "localhost:5601"
EOF

if ! sudo filebeat modules enable system >/dev/null 2>&1; then
echo "[INFO] Filebeat system module may already be enabled"
fi

restart_service filebeat
enable_service filebeat

echo "[OK] Filebeat running"

##################################
# AUDITD TELEMETRY
##################################

echo "[INFO] Enabling process telemetry..."

if sudo auditctl -l | grep -q "exec_log"; then
echo "[INFO] Process telemetry rule already enabled"
else
sudo auditctl -a always,exit -F arch=b64 -S execve -k exec_log
fi

echo "[OK] Process telemetry enabled"

##################################
# INSTALL ATOMIC RED TEAM
##################################

echo "[INFO] Installing Atomic Red Team..."

if [ -d "$ATOMIC_DIR/.git" ]; then
git -C "$ATOMIC_DIR" pull --ff-only
else
git clone https://github.com/redcanaryco/atomic-red-team.git "$ATOMIC_DIR"
fi

##################################
# INSTALL SIGMA
##################################

echo "[INFO] Installing Sigma CLI..."

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
echo "[SUCCESS] SOC LAB INSTALL COMPLETE"
echo
echo "Kibana:"
echo "http://localhost:5601"
echo
echo "Elasticsearch:"
echo "http://localhost:9200"
echo
echo "Default User Credentials"
echo "username: default"
echo "password: default"
echo
echo "Next Step:"
echo "Install Sysmon + Winlogbeat on Windows VM"
echo
echo "Happy Detection Engineering."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
