# Task Breakdown: 5G Distributed Registration Load Generation

- [x] Analyze the repository scripts to understand the current execution profile (`run_as.py`, `Attack.sh`).
- [x] Determine the commands used for simulating the registration attack (e.g., UERANSIM `nr-ue`, custom scripts).
- [x] Design a method to deploy 200 identical pods in Kubernetes that can execute this simulation concurrently.
- [x] Formulate a synchronization strategy (NTP time barrier).
- [x] Prove NTP barrier works with 10-pod Alpine test (all fired at 09:15:59 exactly).
- [x] Create Dockerfile, entrypoint, config, Job YAML, and launcher script.
- [x] Build PacketRusher Docker image.
- [x] Deploy 5-pod test attack against open5gs core.
- [x] Verify attack pods fire simultaneously and registrations hit the AMF.
- [x] Refine configuration: Implement dynamic IMSI generation based on Pod Index to prevent Authentication Rejects (overlapping UE subscribers).
- [x] Implement Pre-Connection Strategy (Method 3)
    - [x] Revert to internal Pod IP / Host Network bypass
    - [x] Fix GNB ID and Port collisions in entrypoint.sh
    - [x] Update target fire time to direct AMF Pod IP
- [x] Final Verification of Synchronized Attack
    - [x] Run 5-pod 50-UE attack
    - [x] Verify sub-100ms synchronization in PCAP/Logs
    - [x] Confirm 100% registration success rate
- [x] Project Completion and Walkthrough Documentation
- [x] Scale to 1000 UEs
    - [x] Provision 600 new subscribers in MongoDB (IMSI 600–1199)
    - [x] Increase barrier wait to 60s
    - [x] Run 20-pod × 50-UE attack
    - [x] Verify synchronization and success rate in PCAP
- [x] Pod Configuration Experiments
    - [x] Experiment B: 10 pods × 100 UEs (fewer pods, test tighter sync)
    - [x] Experiment C: 10 pods × 100 UEs + 2 AMF replicas (test success rate)

- [x] Phase 3: The 10-AMF Brute Force Scale
    - [x] Inject `NO_PROXY` to `/etc/default/rke2-server` and restart control plane
    - [x] Scale `open5gs-amf` deployment to 10 replicas
    - [x] Modify `entrypoint.sh` to use Kube-Proxy ClusterIP load balancing
    - [x] Build attacker Docker image `v12`
    - [x] Launch 1000 UE attack and verify PCAP

- [x] Phase 4: 2-AMF Architecture Optimization
    - [x] Scale down to 2 AMF replicas
    - [x] Rework load balancing constraints and 20-pod deployment
    - [x] Run definitive 2-AMF optimization test

- [x] Phase 5: The Ultimate Benchmark Matrix
    - [x] Case A: 5 AMFs (The Core-Optimized Balance) - 10 Pods, 4 Sockets
    - [x] Case B: 1 AMF (The Baseline Choke) - 10 Pods, 4 Sockets
    - [x] Finalize Report with Definitive Data

- [x] Phase 6: Full End-to-End Core Scaling
    - [x] Scale AMF/AUSF/UDM to 5 replicas each
    - [x] Run definitive 1000-UE attack
    - [x] Update final report

- [x] Phase 7: Iterative Socket Optimization (2 AMF Baseline)
    - [x] Step 1: 1 Socket per Pod (Complete: 73.6%)
    - [x] Step 2: 2 Sockets per Pod (Complete: 70.0% - tightest sync)
    - [x] Step 3: 4 Sockets per Pod (Complete: 88.7% - optimal queue relief)

- [x] Phase 8: CPU Pinning for 100% Success Rate
    - [x] Pin Open5GS (AMF/AUSF/UDM) to dedicated CPU cores
    - [x] Hard pin attackers to cores 4-7 (Failed: 55.9%)
    - [x] Soft pin: core network only pinned (Success: 97.4%!)

- [x] Phase 9: Multi-Node Distributed Architecture (100% Scale Run)
    - [x] Establish SSH automation between nodes (`10.237.26.63`)
    - [x] Export local MongoDB 1000-subscriber profile
    - [x] Remotely deploy Open5GS Core via Docker-Compose
    - [x] Reconfigure Attacker 8-core node to strike LAN target
    - [x] Create Offline Multi-Node Execution Guide


- [x] Phase 10: Standalone 16-Core Docker Deployment
    - [x] Package standalone Docker bundle (`v20` image with baked-in config)
    - [x] Restore 16-core node connectivity (`10.237.26.63`)
    - [x] Provision 2500 subscriber profiles to remote MongoDB
    - [x] Fix missing `open5gs-udr` and `open5gs-pcf` signaling chain
    - [x] Verify end-to-end registration with single-UE test
    - [x] Run definitive 1000-UE synchronized attack (100% SUCCESS, 21ms)
    - [x] Map saturation point with 2000-UE stress tests (4 vs 1 socket/pod)
    - [x] Identify hardware ceiling with 1500-UE test (Confirmed: 1000 UEs is the limit)
    - [x] Finalize benchmark report and saturation blueprint

**Project Complete: 100% Registration Success Achieved on 16-Core Platform.**
- [x] Final Re-verification of 1000-UE Success for Report Closure
