# Distributed 5G Registration Attack Methodology
*A transition from local script execution to a massive, perfectly-synchronized Kubernetes deployment.*

## 1. The Original Architecture & Limitations

The cloned repository contained bash (`Attack.sh`) and python (`run_as.py`) scripts built for local stress-testing. 

**How it worked:**
- It relied on tools like **Vagrant** (VirtualBox) or **Docker Compose** to run small, localized environments (1 Open5GS Core + 1 or 2 small VM "attacker" boxes).
- To launch the attack, a master script would sequentially SSH into each virtual machine or `docker exec` into each container and fire off the `PacketRusher` or `UERANSIM` binary.

**Why it fails at scale:**
When scaling up to an environment like a massive Kubernetes cluster with a goal of **200 attacking pods**, external orchestration scripts fall apart.
- Connecting to the Kubernetes API to execute a command inside 200 separate pods takes seconds. 
- The 1st pod would receive the attack command and begin registering UEs. 
- By the time the 200th pod received its attack command, the first pod would already be finished. 
- **Result:** You get a slow, rolling wave of traffic over 15 seconds. You do **not** get the instantaneous, simulated "flash crowd" spike required to test the limits of the 5G Core control plane.

## 2. The New Kubernetes-Native Architecture

To solve this, we abandoned the external scripting approach and architected an **internally synchronized, distributed weapon** using four major innovations:

### A. The NTP Time Barrier (Perfect Millisecond Synchronization)
Instead of waiting for an external command to "go", the pods are pre-programmed with a target firing time. 

- The `launch-attack.sh` script grabs the current time on the master node, adds exactly 30 seconds to it, and burns that future Unix Epoch timestamp into the Kubernetes `Job` deployment as the `TARGET_TIME` environment variable.
- Kubernetes starts ripping up the 200 pods. Because pods boot at different speeds, some are ready in 2 seconds, some in 12.
- The `entrypoint.sh` script inside **every single pod** calculates the difference between its local clock (sycned via NTP) and the `TARGET_TIME`. It calls `sleep` for the exact number of remaining seconds.
- **Result:** At exactly `TARGET_TIME`, all 200 pods wake up simultaneously, resulting in a perfect, millisecond-aligned spike of PacketRusher load.

### B. Standard Pod Networking (Preventing SCTP Collisions)
PacketRusher connects to the AMF over the SCTP protocol (Port 9730 locally). 

If we instructed 200 pods to use the Host's network (`hostNetwork: true`), they would all attempt to bind to `0.0.0.0:9730` on the Kubernetes worker nodes, causing a massive crash of `Address already in use` errors.

- **Solution:** We configured the Kubernetes `Job` to use standard overlay `PodNetworking`. 
- **Result:** Each of the 200 pods is assigned its own unique virtual IP address by the CNI. All 200 pods can comfortably bind to Port 9730 concurrently and establish 200 separate SCTP connections to the AMF.

### C. Dynamic Identity Injection (Preventing AMF Rejection)
If 200 pods launched using the exact same static `config.yml`, every single pod would advertise itself as cell tower `000002` and attempt to register SIM Card (IMSI) `999700000000100`. 

The 5G AMF would recognize 200 identical IMSIs trying to register simultaneously from 200 identical cell towers, causing **NGAP Error Indications** and **NAS MAC Verification Failures**, forcing the AMF to drop the traffic.

- **Solution:** We configured the Kubernetes Job specifically as an `Indexed` Job (`completionMode: Indexed`). 
  - Kubernetes passes a sequential ID (`POD_INDEX`: 0, 1, 2... 199) to each pod via the Downward API.
  - The `entrypoint.sh` script intercepts this index and performs a mathematical calculation to invent a unique starting IMSI block and a unique GNodeB ID.
  - E.g: Pod 0 becomes cell tower `000002` and tests IMSIs `100-109`. Pod 1 becomes cell tower `000003` and tests IMSIs `110-119`.
- **Result:** The AMF receives 200 distinct cell tower connections, each requesting registrations for completely unique Mobile Subscribers. All 2,000 UEs are successfully granted `Registration Accept`.

### D. Single-Command Orchestration
The entire heavy lifting is bundled into a single command wrapper. By running:
```bash
./launch-attack.sh 200 10
```
1. The script automatically clears dead instances.
2. Calculates the NTP barriers.
3. Templates the configurations using `sed`.
4. Deploys the manifest to the cluster.

You now possess a fully autonomous, horizontally scalable 5G stress-testing infrastructure that outperforms local scripting by orders of magnitude.
