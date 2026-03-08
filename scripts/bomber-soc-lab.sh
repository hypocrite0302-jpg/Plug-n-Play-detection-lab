#!/bin/bash

set -e

clear

cat << "EOF"

██████╗  ██████╗ ███╗   ███╗██████╗ ███████╗██████╗ 
██╔══██╗██╔═══██╗████╗ ████║██╔══██╗██╔════╝██╔══██╗
██████╔╝██║   ██║██╔████╔██║██████╔╝█████╗  ██████╔╝
██╔══██╗██║   ██║██║╚██╔╝██║██╔══██╗██╔══╝  ██╔══██╗
██████╔╝╚██████╔╝██║ ╚═╝ ██║██████╔╝███████╗██║  ██║
╚═════╝  ╚═════╝ ╚═╝     ╚═╝╚═════╝ ╚══════╝╚═╝  ╚═╝

          ELASTIC SOC LAB DESTRUCTION TOOL

EOF

echo
echo "WARNING: This will completely destroy the SOC lab."
echo

read -p "Lab directory name (default soc-lab): " LAB
LAB=${LAB:-soc-lab}

read -p "Remove Docker images as well? (y/n): " REMOVE_IMAGES
read -p "Uninstall Docker completely? (y/n): " REMOVE_DOCKER

echo
echo "Stopping containers..."

cd ~/$LAB 2>/dev/null || true

docker compose down -v || true

echo
echo "Removing Elastic volumes..."

docker volume rm soc-lab_esdata 2>/dev/null || true

echo
echo "Removing Elastic containers..."

docker rm -f elasticsearch kibana fleet-server 2>/dev/null || true

if [ "$REMOVE_IMAGES" == "y" ]; then
  echo
  echo "Removing Elastic images..."
  docker rmi docker.elastic.co/elasticsearch/elasticsearch:8.12.2 || true
  docker rmi docker.elastic.co/kibana/kibana:8.12.2 || true
  docker rmi docker.elastic.co/beats/elastic-agent:8.12.2 || true
fi

echo
echo "Stopping Filebeat..."

sudo systemctl stop filebeat 2>/dev/null || true

echo
echo "Removing Filebeat..."

sudo dpkg -r filebeat 2>/dev/null || true

sudo rm -rf /etc/filebeat
sudo rm -rf /var/lib/filebeat

echo
echo "Removing auditd rules..."

sudo auditctl -D || true

echo
echo "Removing Atomic Red Team..."

rm -rf ~/atomic-red-team

echo
echo "Removing MITRE dataset..."

rm -rf ~/mitre

echo
echo "Removing lab directory..."

rm -rf ~/$LAB

if [ "$REMOVE_DOCKER" == "y" ]; then
  echo
  echo "Uninstalling Docker..."
  sudo apt purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo rm -rf /var/lib/docker
  sudo rm -rf /etc/docker
fi

echo
echo "Cleaning unused Docker artifacts..."

docker system prune -af || true

echo
echo "SOC LAB DESTROYED SUCCESSFULLY"
echo
echo "Your system is now clean."
echo
echo "You can rebuild the lab anytime using:"
echo
echo "./setup-soc-lab.sh"
echo
