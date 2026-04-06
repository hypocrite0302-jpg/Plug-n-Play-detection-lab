# Up-skill SOC Lab

This repository bootstraps a local detection engineering lab with:

- Elasticsearch
- Kibana
- Fleet Server
- Filebeat
- `auditd` process telemetry
- Atomic Red Team
- Sigma CLI

## Clone

```bash
git clone https://github.com/hypocrite0302-jpg/Up-skill.git
cd Up-skill
```

## Install

Run the full lab setup from the repository root with a single command:

```bash
bash install.sh
```

## Recommended Environment

- Ubuntu VM or Ubuntu on WSL
- Internet access
- `sudo` access
- Docker running if you are using Docker Desktop + WSL integration

## What The Installer Does

`install.sh` is the root entrypoint. It normalizes shell line endings and then runs the main installer in `scripts/setup-soc-lab.sh`.

The installer will:

- Check connectivity
- Install required packages
- Install or verify Docker
- Start Elasticsearch, Kibana, and Fleet Server
- Install and configure Filebeat
- Enable `auditd` exec telemetry
- Clone Atomic Red Team
- Install Sigma CLI

## Quick Start On A Fresh Ubuntu VM

```bash
sudo apt update
sudo apt install -y git
git clone https://github.com/hypocrite0302-jpg/Up-skill.git
cd Up-skill
bash install.sh
```

## Detailed Setup Guide

For a fuller walkthrough, see [docs/INSTALLATION.md](docs/INSTALLATION.md).
