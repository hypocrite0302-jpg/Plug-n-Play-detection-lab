# Technical Walkthrough: Native Lab Setup & Telemetry Ingestion (Days 1 & 2)

## 1. Overview
This guide provides a high-level technical walkthrough for establishing the "Visibility Layer"—the foundational step of the Detection Engineering project. This setup enables unified logging from Windows (VM) and Linux (WSL) into a centralized, containerized SIEM.

## 2. Infrastructure Setup: Dockerized SIEM
To minimize overhead and ensure environment consistency, the SIEM is deployed using Docker.

### Elasticsearch & Kibana Deployment
*   **Elasticsearch:** Serves as the high-speed data store and search engine for logs.
*   **Kibana:** Provides the interface for data visualization and query execution.
*   **Steps:**
    1.  Provision a `docker-compose.yml` file defining the Elastic and Kibana services.
    2.  Set memory limits (`ES_JAVA_OPTS`) to ensure performance on local hardware.
    3.  Configure network bridges to allow communication from external VMs/WSL.

## 3. Endpoint Integration: Windows 10 VM
Native Windows logging is often insufficient for deep detection research; therefore, **Sysmon** is used to provide high-fidelity telemetry.

### Sysmon Configuration
*   **Installation:** Installed Sysmon using a comprehensive configuration (e.g., SwiftOnSecurity).
*   **Critical Events:** Focused on capturing Process Creation (Event ID 1), Network Connections (Event ID 3), and Registry Changes (Event ID 12/13/14).

### Log Shipment (Elastic Agent/Winlogbeat)
*   Deploy the Elastic Agent on the Windows VM to ship:
    *   Standard Security/System Event Logs.
    *   Enhanced Sysmon telemetry.
*   Configure the agent to communicate with the Dockerized Elasticsearch IP.

## 4. Endpoint Integration: Linux (WSL)
The Windows Subsystem for Linux (WSL) presents a unique hybrid OS telemetry opportunity.

*   **Ingestion Method:** Utilized Filebeat or the Elastic Agent within the WSL instance.
*   **Source Data:** Configured log paths for `auth.log`, `syslog`, and potential application logs.
*   **Networking:** Addressed cross-OS network routing to ensure the WSL agent can reach the Docker host.

## 5. Verification: The "Healthy" State
The visibility layer is confirmed complete when:
1.  **Index Creation:** `winlogbeat-*` or `elastic-agent-*` indices are visible in Kibana.
2.  **Telemetry Flow:** A manual action (e.g., executing `powershell.exe` on Windows or `whoami` in WSL) generates a searchable record in the Kibana "Discover" tab within < 30 seconds.
3.  **Field Normalization:** All logs conform to the **Elastic Common Schema (ECS)**, allowing for unified querying across different operating systems.
