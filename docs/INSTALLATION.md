# Installation Guide

This guide shows how to download the repository and run the SOC lab installer from a Linux VM or WSL environment.

## Repository Link

HTTPS clone URL:

```bash
https://github.com/hypocrite0302-jpg/Up-skill.git
```

Clone command:

```bash
git clone https://github.com/hypocrite0302-jpg/Up-skill.git
```

## Recommended Target

Use one of these:

- Ubuntu virtual machine
- Ubuntu on WSL

## Prerequisites

Before running the installer, make sure:

- You have internet access
- You can run `sudo`
- `git` is installed
- If you are using WSL with Docker Desktop, Docker Desktop is running and WSL integration is enabled

## Step 1: Install Git If Needed

```bash
sudo apt update
sudo apt install -y git
```

## Step 2: Clone The Repository

```bash
git clone https://github.com/hypocrite0302-jpg/Up-skill.git
cd Up-skill
```

## Step 3: Run The Installer

From the repository root:

```bash
bash install.sh
```

This is the only command you need to run for the lab bootstrap.

## What `install.sh` Does

The root installer:

- Uses `install.sh` as the single entrypoint
- Normalizes Windows-style line endings if the repo was prepared on Windows
- Delegates to `scripts/setup-soc-lab.sh`

The setup script then:

- Checks internet connectivity
- Installs dependencies
- Installs or verifies Docker
- Creates and starts the Elastic stack
- Waits for Elasticsearch and Kibana to become reachable
- Installs Filebeat
- Configures Filebeat to ship host logs
- Enables `auditd` exec telemetry
- Pulls Atomic Red Team
- Installs Sigma CLI

## Expected Access URLs

After a successful run:

- Kibana: `http://localhost:5601`
- Elasticsearch: `http://localhost:9200`

## Rebuild / Rerun

If you need to run the installer again:

```bash
cd Up-skill
bash install.sh
```

## Teardown

To destroy the lab from the repository root:

```bash
bash scripts/bomber-soc-lab.sh
```

## Troubleshooting

If the installer stops early, check these first:

- Docker is running
- Ports `9200`, `5601`, and `8220` are free
- The VM still has internet access
- You are running inside Linux/WSL, not PowerShell directly

Useful commands:

```bash
docker ps
docker logs elasticsearch
docker logs kibana
```
