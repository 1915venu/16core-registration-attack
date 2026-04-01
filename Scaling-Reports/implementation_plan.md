# Implementation Plan: Standalone 16-Core Deployment (100% Success Strategy)

## Goal
To achieve a **100% registration success rate for 1000 UEs** by migrating the attack to a high-performance 16-core standalone machine (`10.237.26.63`). This eliminates the Level 4 SCTP firewall drops encountered in the multi-node campus architecture.

---

## Proposed Changes

### 1. Standalone Core Network (Docker-Compose)
We will deploy a full standalone Open5GS core on the 16-core host using containerized replicas.
#### [NEW] `udr.yaml` and `pcf.yaml` Configs
- Provision missing UDR and PCF network functions to fix registration rejects.
- Bind all NFs to the host loopback (`127.0.0.1`) for maximum performance.

### 2. Attacker Node (PacketRusher)
We will use a specialized Docker image (`v20`) that embeds the attack configuration statically to bypass volume mounting issues.
#### [NEW] `packetrusher-attack:v20`
- Baked-in `config.yml` targeting local AMF.
- Dynamically calculated IMSIs, GNB IDs, and ports per pod index.

### 3. Subscriber Provisioning
- Import 1121 subscriber profiles derived from the 8-core machine's production database into the local MongoDB instance.

---

## Verification Plan
1. **Single-UE Baseline**: Run a minimal test to confirm the AMF-AUSF-UDM-UDR-PCF-MongoDB signaling chain is functional.
2. **Synchronized 1000-UE Attack**: Execute `bash run_docker_attack.sh` to fire 10 synchronized containers (100 UEs each).
3. **Capacity Validation**: Check AMF logs and PacketRusher metrics to verify 1000 success registrations.
4. **Optimization**: If latency spikes, apply CPU core pinning (`taskset`) to the AMF processes.
