# SOC Lab: The Ultimate Detection Engineering Playground

Welcome to the lab. If you're here, you're either a gladiator in the SOC arena or an architect looking to build a fortress. This project isn't just a collection of scripts; it's a fully orchestrated detection engineering ecosystem built to survive the chaos of real-world telemetry.

---

## 1. The Vision (The "Why")
Let's be real: setting up a proper SOC lab usually feels like trying to assemble IKEA furniture in the dark with missing parts. You spend more time troubleshooting Docker networks and Java heap sizes than actually hunting threats. 

We built this lab to kill that friction. It's a one-command bootstrap that spins up an Elastic Stack (8.12.2), configures telemetry via Filebeat and auditd, and arms you with Atomic Red Team and Sigma CLI. It’s built for the developer who wants to move fast without breaking their sanity.

## 2. The Blueprint (The "How")
The architecture is designed for "accessible precision." We're leveraging Docker to keep the Elastic Stack isolated and reproducible, while using native Linux services (`auditd`, `Filebeat`) to capture high-fidelity telemetry from the host.

### High-Level Architecture
- **Elasticsearch (v8.12.2):** Our central nervous system. We've disabled security for the lab (xpack.security.enabled=false) to keep the barrier to entry low—don't do this in production unless you want to be the next headline on Krebs on Security.
- **Kibana:** The single pane of glass for all your "Happy Hunting" moments.
- **Fleet Server:** Orchestrating Elastic Agents, because manual configuration is so 2015.
- **Telemetry Layer:** Filebeat handles the system and auth logs, while `auditd` is hooked into `execve` syscalls to catch every single command execution.

---

## 3. The Grunt Work (Project Stages)

### Stage 1: The Bootstrap & Environment Sanitization
Before we touch a single Docker image, we audit the environment. The `setup-soc-lab.sh` script starts by checking if ports 9200, 5601, and 8220 are already taken by some zombie process.

**Technical Context:**
We use a robust error handler (`error_exit`) combined with `set -o pipefail`. This ensures that if any part of a piped command fails, the whole script halts instead of blindly charging forward into a broken state.

**Developer Note:**
Creating the `default` user might seem like overkill, but it ensures that permissions are consistent across the lab. Plus, it gives you a clean slate so you don't mess up your primary WSL user's environment.

### Stage 2: Orchestrating the Stack
We spin up the Elastic trio using Docker Compose. 

**Deep Dive: Resource Management**
```yaml
elasticsearch:
  environment:
    - ES_JAVA_OPTS=-Xms1g -Xmx1g
```
We've pinned the Java heap size to 1GB. Why? Because Elasticsearch is a memory-hungry beast that will happily eat all your RAM if you let it. On a dev machine or WSL instance, 1GB is the "sweet spot" between performance and not crashing your entire OS.

### Stage 3: Telemetry Hookup (The Fun Part)
This is where the lab starts breathing. We install Filebeat and configure it to watch `/var/log/syslog` and `/var/log/auth.log`.

**Implementation Detail:**
```bash
sudo auditctl -a always,exit -F arch=b64 -S execve -k exec_log
```
This single line is the MVP of the lab. It tells the Linux kernel to log every 64-bit process execution. When you run an "Atomic" test later, this is how you'll catch it in Kibana.

### Stage 4: Armory (Atomic Red Team & Sigma)
A SOC lab without threats is just a fancy log viewer. We pull in Atomic Red Team for execution and Sigma CLI for detection logic.

**Developer Note:**
The scripts pull the MITRE ATT&CK dataset directly. Actually, having the raw JSON locally means you can run your own analysis scripts without worrying about rate-limiting or internet hiccups mid-demo.

---

## 4. The "Big Red Button" (The Bomber Script)
Eventually, you'll break something. Or you'll want to wipe the slate clean. That's where `bomber-soc-lab.sh` comes in.

**Technical Context:**
It doesn't just `docker stop`. It performs a surgical strike:
1. Stops and removes containers.
2. nukes volumes (say goodbye to that 10GB of test logs).
3. (Optional) Purges Docker entirely if you've really messed up your engine.

**Developer Note:**
We added a prompt to remove Docker images. If you're low on disk space, say 'y'. Those Elastic images are heavy—think of it as digital spring cleaning.

---

## 5. Happy Hunting (Conclusion)
You're now armed with a professional-grade detection engineering lab. Your next manual step is to hook up a Windows VM with Sysmon and Winlogbeat, pointing them at your WSL IP.

Go forth, execute some Atomics, and see if your Sigma rules actually fire. To be honest, the first time a rule hits, you'll feel like a wizard.

**Happy Hunting.**
