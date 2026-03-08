# Technical Walkthrough: Native Lab Setup & Telemetry Ingestion (Days 1 & 2)

## 1. Overview
This guide documents the "Visibility Layer" build using a Lab-as-Code approach. We leverage Bash for infrastructure orchestration, Docker Compose for SIEM deployment, and PowerShell for automated endpoint telemetry ingestion.

## 2. Infrastructure Deployment (Linux/WSL)
The SIEM stack is hosted on a Linux/WSL environment. The following script automates the installation of Docker and the initialization of the Elastic container ecosystem.

### Setup Script (`deploy-elastic.sh`)
```bash
#!/bin/bash
echo "[+] Updating system and installing Docker..."
sudo apt update -y && sudo apt install -y docker.io docker-compose
sudo systemctl enable --now docker

echo "[+] Organizing workspace..."
mkdir -p ~/elastic-lab && cd ~/elastic-lab

echo "[+] Initializing Elastic Stack (v8.12.2)..."
# The docker-compose.yml (detailed below) is moved here
docker-compose up -d

echo "[+] Deployment Complete. Kibana: http://localhost:5601"
```

### SIEM Orchestration (`docker-compose.yml`)
We use **Elastic v8.12.2** with security disabled for lab simplicity and a **Fleet Server** container for future agent management.

```yaml
version: '3.7'
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
    networks:
      - elastic

  kibana:
    image: docker.elastic.co/kibana/kibana:8.12.2
    container_name: kibana
    environment:
      - ELASTICSEARCH_HOSTS=http://elasticsearch:9200
      - xpack.security.enabled=false
    ports:
      - "5601:5601"
    depends_on:
      - elasticsearch
    networks:
      - elastic

  fleet-server:
    image: docker.elastic.co/beats/elastic-agent:8.12.2
    container_name: fleet-server
    command: >
      /usr/bin/elastic-agent run
      --fleet-server
      --fleet-server-es=http://elasticsearch:9200
      --fleet-server-host=0.0.0.0
      --fleet-server-insecure-http
    ports:
      - "8220:8220"
    depends_on: [kibana, elasticsearch]
    networks:
      - elastic
    restart: on-failure

networks:
  elastic:
```

## 3. Windows Endpoint Integration
Telemetry is pulled from the Windows VM using Winlogbeat, specifically targeting **Sysmon** logs for high-fidelity process and network monitoring.

### Automated Ingest Script (`install-winlogbeat.ps1`)
This script handles the download, directory mapping, and configuration of the log shipper.

```powershell
$ES_HOST = "http://<YOUR_DOCKER_HOST_IP>:9200"
$KIBANA_HOST = "http://<YOUR_DOCKER_HOST_IP>:5601"
$VERSION = "8.12.2"

# 1. Download and Extract
Invoke-WebRequest "https://artifacts.elastic.co/downloads/beats/winlogbeat/winlogbeat-$VERSION-windows-x86_64.zip" -OutFile winlogbeat.zip
Expand-Archive winlogbeat.zip -DestinationPath C:\
Rename-Item -Path "C:\winlogbeat-$VERSION-windows-x86_64" -NewName "C:\Program Files\Winlogbeat"
Set-Location "C:\Program Files\Winlogbeat"

# 2. Configure for Sysmon Operational logs
@"
winlogbeat.event_logs:
  - name: Microsoft-Windows-Sysmon/Operational
    ignore_older: 72h

output.elasticsearch:
  hosts: ["$ES_HOST"]
setup.kibana:
  host: "$KIBANA_HOST"
"@ | Set-Content -Path .\winlogbeat.yml -Encoding UTF8

# 3. Installation
.\winlogbeat.exe setup
.\winlogbeat.exe install
Start-Service winlogbeat
```

## 4. Verification & Health Check
1.  **SIEM Check:** Verify containers are running via `docker ps`.
2.  **Shipper Check:** Run `Get-Service winlogbeat` on Windows to ensure the agent is active.
3.  **Data Flow:**
    *   Navigate to Kibana -> Stack Management -> Index Management.
    *   Confirm the presence of `winlogbeat-8.12.2-*` indices.
    *   Search for `event.code: 1` (Sysmon Process Creation) to verify high-fidelity data ingestion.
