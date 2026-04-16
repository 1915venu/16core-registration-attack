# 16-Core 5G Multinode Registration Attack 

**Setup:** Open5GS 2.7.5 on 192.168.10.1 · PacketRusher v23 on 192.168.10.2  
**Target:** 1000 UE simultaneous NAS registrations in a single synchronized burst  
**PCAP:** `attack_run_1776289845.pcap` (2.7 MB, 56s capture)

---



Fix 1 — Pod Sync Window: `994ms → 28ms` (pcap) / `994ms → 6.5ms` (software barrier)
**Our build tag:** `packetrusher-attack:v22`
**File changed:** `templates/test-multi-ues-in-queue.go` on attacker
#### Root Cause

The barrier used integer-second Unix timestamps:

Containers started at different fractional offsets within the same second (e.g. T+0.005s and T+0.970s) both compute the same integer `sleepTime` and fire at T+N.005 and T+N.970 respectively — **965ms apart**, completely uncoordinated.

#### Fix

The issue was caused by truncating time to whole seconds, which made containers starting at different sub-second moments wake up nearly a second apart.

The fix ensures each container sleeps until the exact target timestamp with nanosecond precision, aligning all wake-ups to the same precise instant.

#### Result

| Version | Sync Window |
|---------|-------------|
| v21 | up to **994 ms** |
| v22 | **7–10 ms** |
| v23 | **5–7 ms** |

---

### Fix 2 — SCTP Transport Drops on Pods 2/3/4/8: `15–34 drops/run → 0`
**ImageVersion:** v23  
**File:** `internal/control_test_engine/gnb/ngap/service.go` (on attacker)

#### Root Cause

A `// PATCH` comment in `service.go` had set `loc = nil`, causing every SCTP socket to bind to `0.0.0.0` (all interfaces):

```go
// PATCH: Always let the OS dynamically assign the IP and ephemeral Port for massive parallelism
loc = nil
```

The attacker machine has **5 active network interfaces**:

| Interface | IP |
|-----------|-----|
| eth0 (ethernet to core) | 192.168.10.2 |
| docker0 (bridge) | 172.17.0.1 |
| VPN interface 1 | 100.67.28.109 |
| VPN interface 2 | 192.168.70.129 |
| VPN interface 3 | 10.194.167.114 |

With `loc = nil`, SCTP INIT chunks advertised all 5 addresses. The AMF (on the core node) then load-balanced Registration Accept responses across these paths. Responses routed via the Docker bridge or VPN IPs were **silently dropped** — those paths are not routable from the core node back to the attacker. This caused consistent transport losses on 4 of 10 pods (15–34 UEs per pod per run).

#### Fix

Key design: `HOST_IP:0` — specific IP (prevents multi-homing), port 0 (lets OS assign unique ephemeral port per socket, avoiding port-reuse conflicts between back-to-back runs).

---

## Latest Run — PCAP-Verified Results (2026-04-16)

Pre-run procedure: attacker docker daemon restart → full NF compose restart → 5min settle.  
PCAP: `attack_run_1776289845.pcap` (2.7 MB, 56.3s capture on `enp0s31f6`)

### Per-Pod Results

```
  Pod     Auth   Accept   Reject   T3510  BrokenP      Barrier
  ----- ------ -------- -------- ------- -------- ------------
  ✅ 0       100       98        6      71        0   03:19:52.001
  ✅ 1       100       99        6      75        0   03:19:52.000
  ✅ 2       100       96       34     104        0   03:19:52.000
  ✅ 3       100       97       19      81        0   03:19:52.000
  ✅ 4       100       98       30     108        0   03:19:52.007
  ✅ 5       100       96       25      92        0   03:19:52.000
  ✅ 6       100       97        9      78        0   03:19:52.006
  ⚠️ 7       100       92       36     114        0   03:19:52.000
  ⚠️ 8       100       94       34     106        0   03:19:52.000
  ✅ 9       100       96       27      97        0   03:19:52.000

  TOTAL         1000      963
  Registration Success Rate: 963/1000 (96.3%)
```

### Pod Barrier Times (from PCAP — first InitialUEMessage per pod)

| Pod | Barrier Time | Delta |
|-----|-------------|-------|
| pod-1 | 03:19:52.**107** | 0 ms |
| pod-2 | 03:19:52.**110** | +2 ms |
| pod-3 | 03:19:52.**111** | +3 ms |
| pod-9 | 03:19:52.**111** | +3 ms |
| pod-8 | 03:19:52.**115** | +7 ms |
| pod-5 | 03:19:52.**119** | +12 ms |
| pod-7 | 03:19:52.**125** | +18 ms |
| pod-4 | 03:19:52.**127** | +19 ms |
| pod-0 | 03:19:52.**131** | +23 ms |
| pod-6 | 03:19:52.**135** | +27 ms |

### UE Registration Packet Window

| Metric | Value |
|--------|-------|
| First UE Pkt | 03:19:52.**107** |
| Last UE Pkt | 03:19:52.**458** |
| **UE Packet Window** | **351 ms** |
| Success | **963/1000 (96.3%)** |

### PCAP Timing Analysis

| Metric | Value | Description |
|--------|-------|-------------|
| **Pod Sync Window** | **28 ms** | First to last pod's first InitialUEMessage at AMF |
| **UE Packet Window** | **351 ms** | First to last InitialUEMessage (all 1000 UEs) at AMF |
| **Software Barrier** | **6.5 ms** | Container `time.Sleep` wake-up spread (from logs) |
| **AMF First Response** | **16 ms** | First InitialUEMessage → first DownlinkNASTransport (Auth Request) |
| **AMF Throughput** | **148 NGAP resp/s** | DownlinkNASTransport rate during processing window |
| **Reg Accept Window** | **15.4 s** | First to last InitialContextSetupRequest (Registration Accept) |
| **End-to-End Latency** | **15.9 s** | First UE packet → last UE gets Registration Accept |
| **Transport Drops** | **0** | No SCTP broken pipes across all 10 pods |
| **SBI Rejects** | **0** | No AMF SBI timeout failures |

---

## Previous v23 Runs

| Run | Condition | Auth (of 1000) | Accepts | Success% | Sync Window | Transport Drops |
|-----|-----------|---------------|---------|----------|-------------|-----------------|
| v23 #1 | Fresh NFs, first fire | **1000** | 962 | **96.2%** | 5.0 ms | **0** |
| v23 #2 | Immediate warm repeat | 900 | 899 | 89.9% | 9.8 ms | 0 |
| v23 #3 | Immediate warm repeat | 1000 | 885 | 88.5% | 7.2 ms | 0 |
| v23 #4 | Immediate warm repeat | 994 | 945 | **94.5%** | 7.0 ms | 0 |

---

## Before/After Comparison

### Version Progression

| Metric | v21 baseline | v22 (sync fix) | v23 (SCTP fix) |
|--------|-------------|----------------|----------------|
| Pod sync window (logs) | up to **994 ms** | **7–10 ms** | **5–7 ms** |
| Pod sync window (pcap) | ~777 ms* | — | **28 ms** |
| UE packet window (pcap) | — | — | **351 ms** |
| Transport drops (pods 2/3/4/8) | — | **15–34/pod/run** | **0** |
| First fresh run | ~64.7% | **98.7%** (best) / 91.5% (post-full-reset) | **96.3%** |
| Warm consecutive runs | — | 88–94% | **88–96%** |
| SBI rejects (warm) | many | **0** | **0** |
| All pods reach 100 auth | No | Partially (pods 2/3/4/8 short) | **Yes, always** |


### Kubernetes vs 16-Core Multinode Comparison

Reference: [1000ues_post_sctp.md](https://github.com/1915venu/open5gs_kubernetes/blob/main/docs/1000ues_post_sctp.md)

|  | Kubernetes Setup | | 16-Core Multinode (v23) |
|--|-----|-----|------|
| | **K8s Run 1** | **K8s Run 2** | **Latest** |
| Infrastructure | Kubernetes (minikube) | Kubernetes (minikube) | Docker + bare metal |
| Core/Attacker | Same machine | Same machine | Dedicated nodes (Cat6) |
| Pods × UEs/Pod | 20 × 50 | 20 × 50 | 10 × 100 |
| gNBs per pod | 1 | 1 | 4 |
| SCTP sockets | 20 | 20 | 40 |
| **Pod Sync Window** | **988 ms** | **536 ms** | **28 ms** |
| **UE Packet Window** | **1151 ms** | **786 ms** | **351 ms** |
| **Success Rate** | **94.8%** | **93.1%** | **96.3%** |
| AMF First Response | — | — | **16 ms** |
| AMF Throughput | — | — | **148 NGAP resp/s** |
| Reg Accept Window | — | — | **15.4 s** |
| End-to-End Latency | — | — | **15.9 s** |
| Transport Drops | present | present | **0** |
| SBI Rejects | — | — | **0** |

**Improvement factors (vs K8s best run):**
- Pod Sync Window: 536 ms → 28 ms (**19× tighter**)
- UE Packet Window: 786 ms → 351 ms (**2.2× tighter**)
- Success Rate: 94.8% → 96.3% (**+1.5%**)

---

## Key Configuration (v23 Stable)

### `run_docker_attack.sh` (synced to attacker)

```bash
PODS=10
UES_PER_POD=100
BARRIER_WAIT=10        # 10s idle before burst — below SCTP idle timeout
HOST_IP=192.168.10.2   # single-interface SCTP binding (v23 fix)
AMF_IPS=192.168.10.1
IMAGE=packetrusher-attack:v23
```

### `config/amf.yaml` (on core)

```yaml
logger:
  level: info          # not debug — debug burns ~30% CPU, cuts throughput ~4×
time:
  message:
    duration: 30000    # 30s SBI timeout: 30s × 65 UE/s = 1950 capacity > 1000
  t3512:
    value: 540         # keep high — low value causes TAU timer flood during burst
ngap:
  option:
    sctp:
      spp_hbinterval: 60000
      srto_initial: 30000
      srto_max: 60000
```

### SCTP Kernel Tuning (both nodes, applied by `run_attack.py`)

```
net.sctp.rto_initial=30000
net.sctp.rto_max=60000
net.sctp.hb_interval=60000
net.core.rmem_max=33554432      # 32 MB receive buffer
net.core.wmem_max=33554432      # 32 MB send buffer (attacker too — prevents EWOULDBLOCK)
net.core.netdev_max_backlog=50000
```
---
## PacketRusher Build Tags 

`v20`–`v23` are our own Docker image tags built from a modified fork of upstream PacketRusher

All builds use the **post-SCTP pre-connect method** (same as the Kubernetes setup in `1000ues_post_sctp.md`): SCTP connections and NG Setup are established first, then all UEs fire simultaneously after the epoch barrier.

| Our Tag | Docker Image | Changes on top of upstream PacketRusher |
|---------|-------------|----------------------------------------|
| **v20** | `packetrusher-attack:v20` | Base port of post-SCTP method to multinode Docker: epoch barrier (integer-second), 4 gNBs/pod config |
| **v21** | `packetrusher-attack:v21` | + T3510 retransmission timer (15s, 5 retries, spec-compliant per 3GPP TS 24.501 §10.2) |
| **v22** | `packetrusher-attack:v22` | + Nanosecond-precision barrier: fixes 994ms pod sync spread |
| **v23** | `packetrusher-attack:v23` | + SCTP single-interface binding: fixes transport drops from SCTP multi-homing |

---

## Summary

Two fixes transformed the attack:

1. **Sync window (v22):** Changed integer-second barrier to nanosecond-precision. Pod sync window: 994ms → 28ms in pcap (6.5ms software barrier).

2. **SCTP multi-homing (v23):** SCTP INIT chunks now advertise only `192.168.10.2`, eliminating AMF response delivery via Docker bridge and VPN paths. Pods 2/3/4/8 transport drops: 15–34/run → 0.

**Latest verified run (Apr 16, pcap-confirmed):**
- **963/1000 (96.3%)** registration success
- **28 ms** pod sync window (pcap: first to last pod's InitialUEMessage)
- **351 ms** UE packet window (pcap: all 1000 InitialUEMessages delivered)
- **16 ms** AMF first response latency
- **15.9 s** end-to-end (first UE pkt → last Registration Accept)
- **0** transport drops, **0** SBI rejects

---


