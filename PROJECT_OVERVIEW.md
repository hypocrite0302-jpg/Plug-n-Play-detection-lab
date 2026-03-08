# Project: Detection Engineering & Threat Research Lab

## 1. Intent
The primary objective of this project is to bridge the gap between theoretical security concepts and operational execution. By building a native, hybrid-OS environment from the ground up, the intent is to master the "Visibility Layer" of security operations. This project focuses on the full lifecycle of a detection: from raw telemetry ingestion and normalization to rule creation (Sigma/KQL) and scientific validation through adversary simulation.

## 2. Scope
The project scope encompasses:
*   **Infrastructure:** A containerized SIEM (Elasticsearch & Kibana) deployed via Docker.
*   **Endpoints:** A hybrid environment consisting of a Windows 10 Virtual Machine and a Windows Subsystem for Linux (WSL) instance.
*   **Telemetry:** High-fidelity host logging via Sysmon and native system logs.
*   **Detection:** Development and tuning of vendor-neutral Sigma rules and SIEM-specific queries.
*   **Validation:** Leveraging the MITRE ATT&CK framework and Atomic Red Team for evidence-based testing.

## 3. Milestones & Documentation Roadmap
The project is structured into four distinct phases, each culminating in a dedicated technical write-up.

### Phase 1: The Visibility Layer (Week 1)
*   **Goal:** Establish a stable telemetry pipeline.
*   **Write-up Focus:** Infrastructure as Code (Docker), Sysmon configuration, and the "Top 10" critical telemetry fields for host-based analysis.

### Phase 2: Detection Logic & Normalization (Week 2)
*   **Goal:** Transition from "searching" to "detecting."
*   **Write-up Focus:** Sigma rule development, KQL/EQL translation, and strategies for reducing False Positives (FPs) in production-like environments.

### Phase 3: Adversary Simulation & Validation (Week 3)
*   **Goal:** Scientifically verify detection efficacy.
*   **Write-up Focus:** Building a test harness, executing Atomic Red Team simulations, and performing gap analysis on existing telemetry.

### Phase 4: Threat Hunting & Operationalization (Week 4)
*   **Goal:** Proactive discovery and automation.
*   **Write-up Focus:** Hypothesis-driven hunting, alert enrichment automation (Python), and a final retrospective on building a security-first mindset.
