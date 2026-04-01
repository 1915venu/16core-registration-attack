# 16-Core Machine Context for Antigravity

## Machine Info
- **Hostname**: venu-OptiPlex-5070 (16-core CPU)
- **OS**: Ubuntu (same user `venu`, password `iotlab@IITD`)
- **IP (Wired LAN)**: 10.237.26.63 (from 8-core machine at 10.42.0.29)
- **Docker**: v29.3.1 installed
- **Kubernetes**: kubectl installed but NO active cluster (API server not running)

## Project Goal
Run a synchronized **1000-UE 5G registration attack** using PacketRusher against a local Open5GS core, entirely on this 16-core machine. Target: **100% registration success rate**.

## Current Architecture
Everything runs locally on `127.0.0.1` via Docker with `network_mode: host`:

```
PacketRusher (10 Docker containers, 100 UEs each)
    ↓ SCTP (port 38412)
Open5GS AMF → AUSF → UDM → UDR → MongoDB
```

## File Locations

### Open5GS Core (Docker Compose)
- **Docker Compose**: `docker-compose.yaml`
- **AMF Config**: `config/amf.yaml`
- **AUSF Config**: `config/ausf.yaml`
- **UDM Config**: `config/udm.yaml`
- **UDR Config**: `config/udr.yaml`
- **NRF Config**: `config/nrf.yaml`

### Attack Bundle
- **Docker Image**: `packetrusher-attack:v20` (built via `Dockerfile-static`)
- **Launch Script**: `run_docker_attack.sh`
- **Config Template**: `packetrusher_config.yml`

## How the Attack Works

### Entrypoint Logic (`/packetrusher/entrypoint.sh` inside the container)
1. Reads env vars: `POD_INDEX`, `NUM_UE`, `HOST_IP`, `AMF_IPS`, `TARGET_TIME`
2. Calculates unique MSIN (IMSI) and GNB_ID per pod to avoid collisions
3. Copies `/tmp/config-template/config.yml` → `/tmp/config.yml`
4. Uses `sed` to replace placeholders (`@AMF_IP@`, `@MSIN_START@`, etc.)
5. Runs: `./app --config /tmp/config.yml multi-ue -n $NUM_UE --timeBetweenRegistration 1`

### Launch Script (`run_docker_attack.sh`)
- Calculates a synchronized `TARGET_TIME` (current time + 65 seconds)
- Spawns 10 Docker containers with `--network host --privileged`
- Each container gets unique `POD_INDEX` (0-9), `NUM_UE=100`, `AMF_IPS=127.0.0.1`

### NTP Barrier Synchronization
PacketRusher has a built-in NTP barrier: it pre-connects the gNB to the AMF via SCTP immediately, then waits until `TARGET_TIME` to fire all UE registrations simultaneously.

## Final Results (16-Core Standalone Validation)
| Config | Success Rate | Burst Window | Notes |
|--------|-------------|-------------|--------|
| **1000 UEs (0-sec stagger, 4 sockets/pod)** | **95.2%** | **994 ms** | **Baseline Record**. High success, AMF N2 queue stable. |
| 1000 UEs (0-sec stagger, 10 sockets/pod) | 88.7% | - | Massive SBI timeout (`SBI transaction removed`). |
| 1000 UEs (5-sec stagger, 1 socket/pod) | **100%** | 45 s | Total success achieved by artificially pacing the AMF HTTP2 target queues. |
| 1500 UEs (Max Capacity push) | 0% | - | Hard limit of the 16-Core hardware queue (Control processing overload). |

> **Conclusion**: The primary scaling bottleneck across the 16-core configuration is *not* SCTP/N2 mapping, but the AMF's **SBI HTTP2 client requests** to the AUSF/UDM. When 1000 UEs trigger authentication strictly simultaneously in a <1 second window, the queries overwhelm MongoDB, causing the AMF HTTP2 client timers to expire before the backend auth vectors can be calculated. Configuring 4 sockets per pod (40 total SCTP streams) at a 0s stagger creates just enough intrinsic OS pacing to effectively achieve >95% success.

## Environment Fixes
1. **"Payload was not forwarded"** → Missing UDR container. Fixed by adding `open5gs-udr` to docker-compose.yaml.
2. **UDR "Failed to connect to mongodb://mongo"** → UDR default expects hostname `mongo`. Fixed by adding `db_uri: mongodb://127.0.0.1/open5gs` to `udr.yaml`.
3. **Campus switch blocks SCTP** → IIT Delhi managed switches perform L4 DPI, dropping SCTP protocol 132. Solution: run everything locally on one isolated machine.
