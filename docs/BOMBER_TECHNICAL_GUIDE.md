# Technical Deep-Dive: `bomber-soc-lab.sh`

When the lab becomes a "toxic asset"—either through a botched config or a successful (and destructive) malware simulation—you need a way to purge the environment. Enter the Bomber script.

---

## 1. The Philosophy: Surgical Strike
A simple `rm -rf` isn't enough when you're dealing with Docker volumes and kernel-level audit rules. The Bomber script is designed to be destructive but disciplined.

---

## 2. The Destruction Logic

### Step 1: Docker De-Orchestration
We move into the lab directory and run `docker compose down -v`. 
- **The `-v` Flag:** This is critical. It doesn't just stop the containers; it nukes the anonymous volumes. If you omit this, your next lab run might inherit "ghost" data from the previous failed run.

### Step 2: Volume Purging
We explicitly call `docker volume rm soc-lab_esdata`. This is the "scorched earth" policy for your indices. It ensures that 10GB of log data isn't sitting in your WSL VHDX file eating up space on your Windows host.

### Step 3: Telemetry Rollback
We run `auditctl -D`. 
- **Why?** Because kernel audit rules persist. If you delete the lab but leave the rules, your system logs will continue to fill up with execution data for a listener that no longer exists. We clean up after ourselves.

### Step 4: Tooling Removal
We purge the `atomic-red-team` and `mitre` datasets. These are large git repos and JSON files. Deleting them ensures the lab's footprint is exactly zero when you're done.

---

## 3. The "Nuclear" Option: Uninstalling Docker
The script offers a prompt to uninstall the Docker engine entirely.
- **The Reason:** Sometimes the Docker daemon itself gets into a weird state in WSL. This purge removes `/var/lib/docker` and `/etc/docker`, effectively resetting your container engine to factory defaults.

---

## 4. Developer Note: The Prune
We finish with `docker system prune -af`. To be honest, this is the most satisfying part of the script. It clears out the build cache and any dangling images, reclaiming those precious gigabytes.

**Happy Nuking.**
