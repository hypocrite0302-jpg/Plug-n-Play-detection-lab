# Windows Deployment TODO

This repo is ready for Linux/WSL stack bootstrap today. The next extension track is a guided Windows endpoint deployment flow.

## Priority Backlog

1. Add a `scripts/deploy-windows-endpoint.ps1` bootstrapper for:
   - Sysmon installation with a curated config
   - Winlogbeat installation pinned to the lab stack version
   - Secure output configuration using the saved lab credentials
   - Basic service validation and log-forwarding smoke tests

2. Generate Windows-side credential and endpoint config artifacts from the Linux installer:
   - Beat output target
   - Kibana/Elastic credentials or enrollment alternatives
   - Optional host naming and tagging conventions

3. Add a Windows validation script that checks:
   - Sysmon service state
   - Winlogbeat service state
   - Reachability to Elasticsearch
   - Presence of `winlogbeat-*` or Windows event data in Kibana

4. Add a Windows teardown script that can remove:
   - Sysmon
   - Winlogbeat
   - Generated configs and certificates
   - Scheduled tasks or service registrations created by the bootstrapper

5. Create a cross-platform smoke test path:
   - Emit a Windows event
   - Confirm ingestion into Elasticsearch
   - Confirm Kibana discoverability
   - Confirm field mappings useful for detections

## Nice-To-Have Enhancements

- Generate separate least-privilege service credentials for Beats
- Add a PowerShell TUI matching the Linux installer’s visual language
- Support Elastic Agent or Defender-style telemetry as an optional mode
- Add Sigma-to-Kibana rule import helpers for Windows detections
