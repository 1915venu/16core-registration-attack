# 5G Multinode 1000-UE Registration Attack — Full Experiment Report

**Core Node:** 192.168.10.1 — Open5GS 2.7.5 (Docker Compose)  
**Attacker Node:** 192.168.10.2 — PacketRusher `packetrusher-attack:v20` (Docker)  
**Target:** 1000 UE NAS registrations, synchronized burst (<100ms sync window), 100% success rate  
**Topology:** 10 pods × 100 UEs, 4 gNodeBs per pod (40 SCTP sockets total)

---

## Architecture Overview

```
Attacker Node (192.168.10.2)
┌────────────────────────────────────────────────────────┐
│  Pod 0  │  gNB-0,1,2,3  (4 SCTP sockets, 25 UEs each)  │
│  Pod 1  │  gNB-4,5,6,7                                 │
│   ...   │  ...                                         │
│  Pod 9  │  gNB-36,37,38,39                             │
└─────────────────────┬──────────────────────────────────┘
                      │ 40 SCTP connections to port 38412
                      ▼
Core Node (192.168.10.1)
┌────────────────────────────────────────────────────────┐
│  open5gs-amf  (NGAP :38412, SBI :7778)                 │
│       │                                                │
│  open5gs-ausf (SBI :7779)                              │
│       │                                                │
│  open5gs-udm  (SBI :7780)                              │
│       │                                                │
│  open5gs-udr  (SBI :7781) ──► MongoDB (pool=500)       │
│                                                        │
│  open5gs-nrf  (SBI :7777)                              │
│  open5gs-pcf  (SBI :7782)                              │
│  open5gs-smf  (SBI :7783)                              │
│  open5gs-upf                                           │
└────────────────────────────────────────────────────────┘
```

---

## Phase 1 — Configuration Bugs (All Fixed)

These were blockers that produced 0% or near-0% registration before any architecture work.
## Bugs Summary

| Bug # | Issue | File | Effect | Fix | Detection |
|------|------|------|--------|-----|----------|
| 1 | HOST_IP=127.0.0.1 | run_docker_attack.sh | SCTP bound to loopback, packets never left attacker → 0 auth requests | Set HOST_IP=192.168.10.2 | No auth requests across pods |
| 2 | AMF_IPS=127.0.0.1 | run_docker_attack.sh | gNodeB connected to local loopback instead of core → NGAP failed | Set AMF_IPS=192.168.10.1 | No auth requests |
| 3 | BARRIER_WAIT=65s | run_docker_attack.sh | Idle SCTP → kernel ABORT → broken pipes | Reduce to 10s | Broken pipe logs, SCTP_COMM_LOST |
| 4 | AMF logger=debug | config/amf.yaml | Heavy logging → ~30% CPU usage → low throughput (~9 UE/s) | Set logger level=info | Low accept rate, CPU profiling |
| 5 | MongoDB maxPoolSize=100 | docker-compose.yaml | DB pool exhausted → timeouts → Registration Reject (No NSSAI) | maxPoolSize=500 | AMF log: No Allowed-NSSAI |
| 6 | Missing sd="ffffff" | config/amf.yaml | NSSAI mismatch → all UEs rejected | Add sd="ffffff" | Registration Reject after auth |
| 7 | docker restart issue | docker-compose.yaml | Env changes not applied | Use `docker compose up -d --force-recreate` | docker inspect mismatch |
---

## Phase 2 — Synchronized Burst Problem (Partially Solved)

After fixing all configuration bugs, the remaining problem was delivering 1000 UE registrations simultaneously with both 100% success and a tight sync window.

### The Core Constraint: AMF libuv Event Loop Overflow

**Open5GS AMF is single-threaded, built on libuv.**

When 40 SCTP sockets all deliver Initial UE Messages simultaneously:
1. `epoll_wait()` returns all 40 sockets as readable in a single wake-up
2. AMF reads all 1000 queued NGAP messages from sockets in one event loop iteration
3. AMF attempts to enqueue 1000 handler jobs into its internal dispatch queue
4. **The dispatch queue has fixed capacity — 240 messages are silently discarded**
5. Kernel socket buffers were not the problem — all data was already read into userspace

**Evidence from actual runs:**

| Run | Sockets | Sync Window | Auth Reached AMF | Dropped | Accepted |
|-----|---------|-------------|------------------|---------|----------|
| Single wave, 4 gNB/pod | 40 | 63ms | 760/1000 | 240 | 718/1000 |
| Single wave, 8 gNB/pod | 80 | 63ms | 0/1000 | 1000 | 0/1000 |

The 8-gNB run caused AMF to explicitly send `NG Setup Failure: misc: Control processing overload` — AMF's own overload detection at the NGAP connection setup level.

### AMF Throughput Ceiling

From all successful runs, AMF processes registrations end-to-end (NGAP → AUSF auth → UDM subscription → Registration Accept) at approximately **14 UEs/second**.

For 1000 UEs with T3510=60s (PacketRusher's hardcoded registration timer):
- Maximum processable: 14/sec × 60s = **840 UEs**
- UEs 841–1000 always time out regardless of delivery mechanism

---

## Phase 3 — Approaches Tried (Chronological)

### Attempt 1: Kernel Socket Buffer Tuning
**Hypothesis:** NGAP message drops caused by kernel socket buffer overflow.  
**Applied:**
- `net.core.rmem_max=32MB`, `wmem_max=32MB`
- `net.core.netdev_max_backlog=50000`
- `net.sctp.rcvbuf_policy=1`

**Result:** No improvement. 760/1000 auth delivered (same as before).  
**Why it failed:** Drops happen inside AMF userspace (dispatch queue), not in kernel socket buffers.

### Attempt 2: Increase gNodeBs per Pod (4→8)
**Hypothesis:** More SCTP sockets = smaller burst per socket = less per-read overhead.  
**Result:** AMF replied `NG Setup Failure: misc: Control processing overload`. 0/1000 registered.  
**Why it failed:** More sockets = more simultaneous epoll events = larger dispatch queue overflow per cycle. Made it worse, not better.

### Attempt 3: Two-Wave Launch (3+7 pods, 30s gap) ✅ ACHIEVED 100%
**Approach:** Launch pods 0-2 first (300 UEs, 12 sockets). After 30s sleep in script, launch pods 3-9 (700 UEs, 28 sockets). Each wave gets BARRIER_WAIT=10s of idle time only.

**Critical implementation detail:** Wave 2 containers are launched AFTER the 30s sleep (not pre-launched), so they only idle 10s. Pre-launching both waves simultaneously caused wave 2 to sit idle for 40s → SCTP broken pipes.

**Result: 1000/1000 (100%) — TARGET ACHIEVED**

| Metric | Value |
|--------|-------|
| Registration success | 1000/1000 (100%) |
| Pod sync window | 30,330ms |
| Broken pipes | 0 |
| T3510 timeouts | 0 |

**Why it works:**
- Wave 1: 12 sockets, 300 UEs — within AMF cold-start dispatch capacity
- Wave 2: 28 sockets, 700 UEs — AMF event loop already warmed up, queue has headroom
- 30s gap: AMF fully clears wave 1 before wave 2 arrives

**Why it's not the final answer:** Sync window = 30,000ms. The 1000-UE burst is spread over 30 seconds, not synchronized.

### Attempt 4: Per-Pod Stagger (2s between pods)
**Approach:** Each pod gets its own TARGET_TIME = BASE + i×2s. All containers launched in parallel.  
**Problem:** Containers idle 0–18s waiting for their TARGET_TIME. Pods 6-9 idle >10s → SCTP broken pipes (same issue as BARRIER_WAIT=65s, just per-pod).  
**Result:** Pods 6-9: 72 broken pipes each. 0/1000 accepts.

### Attempt 5: Per-Pod Stagger (5s) + Staggered Container Launch
**Approach:** Launch pod i, sleep 5s, launch pod i+1. Each container fires 10s after its own launch (BARRIER_WAIT=10). No container ever idles more than 10s.

**Result:** 1000/1000 auth reached AMF (0 broken pipes, no NGAP drops!), but **0 accepts**.

All UEs timed out on T3510. Barrier timestamps show pod 0 fired at T, pod 9 fired at T+47s. AMF processes at 14/sec. Pod 0's UEs start completing at T+7s. Pod 9's T3510 expires at T+47+60=T+107s. AMF completes all 1000 UEs at T+71.4s → should be OK. But AMF SBI transaction timer fires before AUSF responds for queued UEs — `SBI transaction already removed` in AMF logs.

**Why it failed:** Even with staggered delivery, AMF's HTTP/2 client to AUSF has its own transaction timeout. When 1000 concurrent auth requests queue at AUSF, AMF's SBI timer expires before AUSF processes the late ones → AMF cancels the request → Registration Reject/timeout.

### Attempt 6: Dual Chain (2× AMF + 2× AUSF + 2× UDM + 2× NRF)
**Approach:** Full independent chain isolation — AMF-1→AUSF-1→UDM-1 on 127.0.0.1, AMF-2→AUSF-2→UDM-2 on 127.0.0.2. PacketRusher round-robins pods across AMF-1 (192.168.10.1) and AMF-2 (192.168.10.3, IP alias on same interface).

**Best result with dual chain:** 779/1000 auth (slight improvement over single-chain 760), but 293 T3510 timeouts. AUSF SBI `transaction already removed` errors still present — shared AUSF per chain still overwhelmed by 500 concurrent requests.

**Status: Pending** — NRF-2 isolation is working. AUSF-2 needs the same staggered approach or the SBI transaction timeout needs increasing.

---

## Summary Table — All Runs

| Run # | Approach | Auth | Accepts | Success% | Sync Window | Key Problem |
|-------|----------|------|---------|----------|-------------|-------------|
| 1 | IPs fixed, BARRIER_WAIT=65s | ~100 | ~22 | ~2% | — | SCTP broken pipes |
| 2 | BARRIER_WAIT=10, no MongoDB fix | 760 | ~450 | ~45% | ~70ms | No Allowed-NSSAI |
| 3 | MongoDB pool=500, NSSAI fixed | 760 | 718 | 71.8% | 63ms | AMF dispatch overflow (240 dropped) |
| 4 | 8 gNB/pod | 0 | 0 | 0% | — | AMF Control processing overload |
| 5 | rmem_max=32MB, netdev_backlog=50k | 760 | 718 | 71.8% | 63ms | Kernel tuning irrelevant for userspace drops |
| 6 | Two-wave 5+5 (pre-launched) | ~309 | 290 | 29% | 30,000ms | Wave 2 SCTP broken pipes (40s idle) |
| 7 | **Two-wave 3+7 (sleep in script)** | **1000** | **1000** | **100%** | **30,330ms** | ✅ 100% but 30s spread |
| 8 | Dual AMF, IP alias 192.168.10.3 | 779 | 620 | 62% | 110ms | Both AMFs hitting same AUSF (NRF override) |
| 9 | Dual chain, NRF-2 isolated | 428 | 187 | 18.7% | 123ms | AUSF-2 not registered (NRF-2 started after) |
| 10 | Dual chain, NRF-2 fixed ordering | 500 | 222 | 22.2% | 61ms | AMF SBI tx timeout to AUSF |
| 11 | Stagger 2s/pod, parallel launch | 900 | 0 | 0% | 17,000ms | Late pods broken pipes + SBI tx timeout |
| 12 | **Stagger 5s/pod, sequential launch** | **1000** | **0** | **0%** | **47,000ms** | 0 NGAP drops but AMF SBI tx timeout |

---

## Pending Fix Options

### Option A: Rebuild PacketRusher with T3510=90s (Best ROI)

### Option B: Two-Wave with Reduced Gap (10s instead of 30s)

### Option C: Full Dual Chain + Stagger (Most Complex)

### Option D: Increase Open5GS SBI Transaction Timeout (Source Change)


---

