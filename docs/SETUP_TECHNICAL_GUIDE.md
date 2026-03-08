# Technical Deep-Dive: `setup-soc-lab.sh`

This isn't your average "copy-paste from a blog post" script. This is an orchestrated bootstrap designed to fail gracefully and build a production-adjacent environment on a developer's budget.

---

## 1. The Strategy: Defensive Scripting
We've implemented `set -e` and `set -o pipefail` at the top. Why? Because in a complex installation, a silent failure in the middle of a pipe is a silent killer. We want the script to scream if something goes wrong.

### The Error Handler
We've hooked into the `ERR` trap with our `error_exit` function. It doesn't just say "it broke"; it offers actual forensic advice—checking `docker logs` and `docker ps` automatically.

---

## 2. Stage-by-Stage Breakdown

### Stage A: Environment Sanitization
Before pulling a single bit from the internet, we check for port conflicts. 
- **Ports:** 9200 (ES), 5601 (Kibana), 8220 (Fleet).
- **The Logic:** We use `lsof -i`. If a port is bound, we stop. This prevents the "Elastic-is-running-but-I-can't-see-my-logs" nightmare caused by overlapping services.

### Stage B: Identity Management
We create a `default` user. This keeps the lab's file ownership consistent and avoids the "permission denied" dance when Docker tries to mount volumes from your WSL home directory.

### Stage C: The Elastic Orchestra (Docker Compose)
We're using **Elasticsearch 8.12.2**. 
- **The Gotcha:** We've explicitly set `xpack.security.enabled=false`. In a lab, certificate management is a distraction. Here, we prioritize speed to telemetry.
- **Resource Pinning:** `ES_JAVA_OPTS=-Xms1g -Xmx1g`. This is non-negotiable for WSL. It prevents the JVM from ballooning and triggering the OOM killer.

### Stage D: The Telemetry Pipeline
We don't just install Filebeat; we configure the `system` module and hook it into the host's `/var/log/syslog`. 
- **Kernel-Level Insight:** `auditctl` is used to track `execve`. Every time a process starts, the kernel takes a note. This is how we catch malicious binaries in the act.

---

## 3. Developer Note: The YAML Trap
The script uses a heredoc to write the `filebeat.yml`. Actually, the most common failure point here is indentation. We've hardcoded the spaces to ensure the YAML parser doesn't throw a tantrum during service startup.

**Happy Installing.**
