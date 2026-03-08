#!/bin/bash

set -e

clear

cat << "EOF"

 ███████╗ ██████╗  ██████╗      ██████╗ ███████╗ ██████╗
 ██╔════╝██╔═══██╗██╔════╝     ██╔════╝ ██╔════╝██╔════╝
 ███████╗██║   ██║██║          ██║  ███╗█████╗  ██║     
 ╚════██║██║   ██║██║          ██║   ██║██╔══╝  ██║     
 ███████║╚██████╔╝╚██████╗     ╚██████╔╝███████╗╚██████╗
 ╚══════╝ ╚═════╝  ╚═════╝      ╚═════╝ ╚══════╝ ╚═════╝

        ULTIMATE DETECTION ENGINEERING LAB
        Elastic • Sysmon • Atomic Red Team
             Full SOC Simulation

EOF

echo
echo "Initializing SOC Lab bootstrap..."
sleep 2

read -p "Lab directory (default soc-lab): " LAB
LAB=${LAB:-soc-lab}

PORTS=(9200 5601 8220)

echo
echo "Checking required ports..."

for PORT in "${PORTS[@]}"; do
  if sudo lsof -i:$PORT >/dev/null 2>&1 ; then
    echo
    echo "ERROR: Port $PORT already in use"
    echo "Stop the service before running installer"
    exit 1
  fi
done

echo "Ports OK"
echo

echo "Installing dependencies..."

sudo apt update

sudo apt install -y \
  curl \
  jq \
  git \
  python3 \
  python3-pip \
  auditd \
  apt-transport-https \
  ca-certificates \
  gnupg

echo
echo "Installing Docker..."

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list

sudo apt update

sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

sudo usermod -aG docker $USER

mkdir -p ~/$LAB
cd ~/$LAB

echo
echo "Creating Elastic stack..."

cat > docker-compose.yml << 'EOF'
version: '3'

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

echo
echo "Pulling Elastic images..."

docker compose pull

echo
echo "Starting Elastic Stack..."

docker compose up -d

sleep 20

echo
echo "Installing Filebeat..."

curl -L -O https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-8.12.2-amd64.deb

sudo dpkg -i filebeat-8.12.2-amd64.deb

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

sudo systemctl enable filebeat
sudo systemctl restart filebeat

echo
echo "Configuring auditd telemetry..."

sudo auditctl -a always,exit -F arch=b64 -S execve -k exec_log

echo
echo "Installing Sigma CLI..."

pip3 install sigma-cli

echo
echo "Installing Atomic Red Team..."

mkdir -p ~/atomic-red-team
cd ~/atomic-red-team

git clone https://github.com/redcanaryco/atomic-red-team.git

echo
echo "Downloading MITRE ATT&CK dataset..."

mkdir -p ~/mitre
cd ~/mitre

curl -O https://raw.githubusercontent.com/mitre/cti/master/enterprise-attack/enterprise-attack.json

echo
echo "Returning to lab directory..."

cd ~/$LAB

echo
echo "SOC LAB INSTALL COMPLETE"
echo

echo "Kibana:"
echo "http://localhost:5601"

echo
echo "Elasticsearch:"
echo "http://localhost:9200"

echo
echo "Telemetry Sources Installed:"
echo
echo "✔ WSL system logs"
echo "✔ WSL auth logs"
echo "✔ Linux process execution (auditd)"
echo
echo "Tools Installed:"
echo
echo "✔ Sigma CLI"
echo "✔ Atomic Red Team"
echo "✔ MITRE ATT&CK dataset"

echo
echo "Next manual step:"
echo
echo "Install Sysmon + Winlogbeat on Windows VM"

echo
echo "Forward logs to:"
echo
echo "http://$(hostname -I | awk '{print $1}'):9200"

echo
echo "Running containers:"
docker ps

echo
echo "Happy Hunting."
