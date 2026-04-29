# Installation Guide

This repo is designed to be run from Ubuntu or Ubuntu on WSL.

## Prerequisites

- internet access
- `sudo` access
- `git`
- Docker available in the Linux environment

If you are using WSL with Docker Desktop, make sure Docker Desktop is already running and WSL integration is enabled.

## Clone

```bash
git clone https://github.com/hypocrite0302-jpg/Plug-n-Play-detection-lab.git
cd Plug-n-Play-detection-lab
```

## Install

```bash
bash install.sh
```

The installer:

- validates dependencies and ports
- bootstraps Elasticsearch, Kibana, and Fleet Server
- generates Elastic and Kibana credentials
- pins Filebeat to the lab stack version
- validates Filebeat config and connectivity
- confirms `filebeat-*` ingestion before declaring success

On WSL, `auditd` is skipped and Filebeat is configured to ingest Bash history, host log files, and Docker container logs instead. The first successful WSL install also resets the Filebeat cursor once so existing local logs are backfilled into Elasticsearch retrospectively.

## Validate Before Rebuild

```bash
bash validate.sh
```

The validator now scans the environment and then offers only two interactive choices:

- delete blockers
- quit

Useful flags:

```bash
bash validate.sh --dry-run
bash validate.sh --deep-clean
bash validate.sh --yes --deep-clean
```

## Credentials

The installer saves runtime credentials here:

```bash
~/soc-lab/.credentials.env
```

That file contains:

- the `elastic` superuser password
- the internal `kibana_system` password
- the Kibana UI username and password you selected or had auto-generated

## Access

After a successful install:

- Kibana: `http://localhost:5601`
- Elasticsearch: `http://localhost:9200`

## Teardown

To remove the lab and host-side telemetry changes:

```bash
bash scripts/bomber-soc-lab.sh
```

Available teardown profiles:

- `light`: remove rebuildable generated config/runtime files only
- `mid`: remove the full lab footprint, including containers, volumes, Filebeat, and telemetry hooks
- `heavy`: remove everything from `mid`, then also remove Docker packages/data and the helper Linux user

Examples:

```bash
bash scripts/bomber-soc-lab.sh --profile light
bash scripts/bomber-soc-lab.sh --profile mid
bash scripts/bomber-soc-lab.sh --profile heavy
```
