#!/bin/bash

set -e
set -o pipefail

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

clear

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

if id "default" &>/dev/null; then
echo "[INFO] User 'default' already exists"
else

echo "[INFO] Creating default user..."

sudo useradd -m -s /bin/bash default || error_exit "User creation failed."

echo "default:default" | sudo chpasswd

sudo usermod -aG sudo default
sudo usermod -aG docker default

echo "[OK] Default user created"

fi

##################################
# CHECK INTERNET
##################################

echo "[INFO] Checking internet connectivity..."

ping -c 1 google.com >/dev/null 2>&1 || error_exit "
Internet connectivity failed.

Fix:
Check network connectivity
Ensure DNS resolution works

Test manually:
ping google.com
"

echo "[OK] Internet working"

##################################
# CHECK PORTS
##################################

PORTS=(9200 5601 8220)

echo "[INFO] Checking required ports..."

for PORT in "${PORTS[@]}"; do

if sudo lsof -i:$PORT >/dev/null 2>&1 ; then

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
auditd \
apt-transport-https \
ca-certificates \
gnupg \
lsb-release || error_exit "
Package installation failed.

Fix:
sudo dpkg --configure -a
sudo apt --fix-broken install
"

echo "[OK] Dependencies installed"

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

sudo systemctl start docker

fi

docker info >/dev/null 2>&1 || error_exit "
Docker daemon not running.

Fix:

If using Docker Desktop:
Start Docker Desktop.

If using Linux:
sudo systemctl start docker
"

echo "[OK] Docker ready"

##################################
# LAB DIRECTORY
##################################

LAB="soc-lab"

mkdir -p ~/$LAB
cd ~/$LAB

##################################
# CREATE ELASTIC STACK
##################################

echo "[INFO] Writing docker compose..."

cat > docker-compose.yml << 'EOF'
services:

 elasticsearch:
  image: docker.elastic.co/elasticsearch/elasticsearch:8.12.2
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
  image: docker.elastic.co/kibana/kibana:8.12.2
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
  image: docker.elastic.co/beats/elastic-agent:8.12.2
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

docker compose pull || error_exit "
Image pull failed.

Fix:
Check internet connectivity.
Try manually:
docker pull docker.elastic.co/elasticsearch/elasticsearch:8.12.2
"

docker compose up -d || error_exit "
Container startup failed.

Fix:
docker logs elasticsearch
docker logs kibana
"

echo "[OK] Elastic stack started"

##################################
# FILEBEAT
##################################

echo "[INFO] Installing Filebeat..."

curl -L -O https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-8.12.2-amd64.deb

sudo dpkg -i filebeat-8.12.2-amd64.deb

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

sudo filebeat modules enable system

sudo systemctl restart filebeat
sudo systemctl enable filebeat

echo "[OK] Filebeat running"

##################################
# AUDITD TELEMETRY
##################################

echo "[INFO] Enabling process telemetry..."

sudo auditctl -a always,exit -F arch=b64 -S execve -k exec_log

echo "[OK] Process telemetry enabled"

##################################
# INSTALL ATOMIC RED TEAM
##################################

echo "[INFO] Installing Atomic Red Team..."

mkdir -p ~/atomic-red-team
cd ~/atomic-red-team

git clone https://github.com/redcanaryco/atomic-red-team.git

##################################
# INSTALL SIGMA
##################################

echo "[INFO] Installing Sigma CLI..."

pip3 install sigma-cli

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
