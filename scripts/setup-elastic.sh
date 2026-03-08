#!/bin/bash

echo "[+] Updating system..."
sudo apt update -y

echo "[+] Installing Docker..."
sudo apt install -y docker.io

echo "[+] Starting Docker..."
sudo systemctl enable docker
sudo systemctl start docker

echo "[+] Installing Docker Compose..."
sudo apt install -y docker-compose

echo "[+] Creating Elastic directory..."
mkdir -p ~/elastic-lab
cd ~/elastic-lab

echo "[+] Creating docker-compose.yml..."

cat <<EOF > docker-compose.yml
version: '3'

services:
  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:latest
    container_name: elasticsearch
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=false
    ports:
      - "9200:9200"
    networks:
      - elastic

  kibana:
    image: docker.elastic.co/kibana/kibana:latest
    container_name: kibana
    ports:
      - "5601:5601"
    environment:
      - ELASTICSEARCH_HOSTS=http://elasticsearch:9200
    depends_on:
      - elasticsearch
    networks:
      - elastic

networks:
  elastic:
EOF

echo "[+] Pulling latest Elastic images..."
docker-compose pull

echo "[+] Starting Elastic Stack..."
docker-compose up -d

echo "[+] Done!"
echo "Access Kibana at: http://localhost:5601"
