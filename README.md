# Up-skill SOC Lab

This repository bootstraps a local Elastic-based detection engineering lab for Ubuntu and WSL. The current build path covers Elasticsearch, Kibana, Fleet Server, Filebeat, secure credential bootstrap, and host telemetry with a WSL-friendly fallback when `auditd` is unavailable.

## Core Commands

Install the lab:

```bash
bash install.sh
```

Validate the environment before rebuilding:

```bash
bash validate.sh
```

Choose a teardown depth when needed:

```bash
bash scripts/bomber-soc-lab.sh --profile light
bash scripts/bomber-soc-lab.sh --profile mid
bash scripts/bomber-soc-lab.sh --profile heavy
```

## What The Installer Handles

- dependency and Docker validation
- secure Elasticsearch and Kibana startup ordering
- Kibana UI credential creation
- Filebeat version pinning to the stack version
- Filebeat config, output, and setup validation
- post-install confirmation that `filebeat-*` data is present
- `auditd` enablement on Linux hosts that support it
- WSL fallback telemetry using Bash history, host logs, and Docker container logs
- one-time retrospective WSL backfill of existing log files on first successful install

Runtime credentials are stored in:

```bash
~/soc-lab/.credentials.env
```

## Repo Guide

- setup guide: [docs/INSTALLATION.md](docs/INSTALLATION.md)
- Windows extension backlog: [TODO-WINDOWS-DEPLOYMENT.md](TODO-WINDOWS-DEPLOYMENT.md)
