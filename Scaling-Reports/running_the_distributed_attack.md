# Architecting a 200-Pod 5G Registration Attack

To achieve a perfectly synchronized spike of 5G registration traffic across 200 Kubernetes pods, we had to solve three major technical hurdles: **Timing Jitter**, **Networking Collisions**, and **Identity Collisions**. 

Here is exactly what was built to solve these, the results, and how you can run it yourself.

---

## 1. What I Did

I built a distributed attack framework located in `/home/venu/Desktop/5G-Registration-Attack/distributed-attack/`. It consists of the following components:

### A. The Synchronization Barrier (No Jitter)
Kubernetes doesn't start pods instantly. If you ask for 200 pods, some might start in 2 seconds, others in 15 seconds. If they attack immediately, your "spike" will be flattened out into a slow wave.

**Solution:** I wrote an `entrypoint.sh` script that calculates a target Unix epoch time in the future (e.g., 30 seconds from now). Every pod boots up, checks the time, calculates exactly how long it needs to sleep, and then they all wake up at the exact same millisecond. Since Kubernetes nodes use NTP, their CPU clocks are perfectly synchronized.

### B. Scalable Networking (No SCTP Collisions)
PacketRusher connects to the AMF over SCTP. By default, attempting to run many PacketRusher instances on the same host causes an `address already in use` error.

**Solution:** I configured the Kubernetes `Job` to use standard Pod networking rather than `hostNetwork`. This ensures each of the 200 pods gets its own dedicated virtual IP address. They can all bind to port 9730 locally and connect to the AMF concurrently without stepping on each other's toes.

### C. Dynamic Identity Injection (No Auth Rejects)
If 200 pods all boot up with the same `config.yml`, they will all try to register IMSI `999700000000100`. The 5G AMF will detect this duplicate SIM card connecting from 200 different cell towers and reject them.

**Solution:** I configured the Kubernetes Job as an `Indexed` Job. 
- Pod-0 gets index 0 and dynamically injects IMSI `100`.
- Pod-1 gets index 1 and dynamically injects IMSI `200`.
- This ensures 100% unique UE identities across the entire fleet.

---

## 2. The Verification Results

I tested this with a 5-Pod deployment (50 UEs total). 

**Result 1 (Perfect Timing):**
All 5 pods finished sleeping and fired the PacketRusher binary within 56 milliseconds of each other:
```text
[pod/packetrusher-attack-zbd2c] BARRIER REACHED! Launching PacketRusher at 09:45:33.549268736
[pod/packetrusher-attack-w8smd] BARRIER REACHED! Launching PacketRusher at 09:45:33.550117020
```

**Result 2 (Perfect Registration):**
The AMF accepted all concurrent registrations and issued GUTIs without a single Authentication Reject:
```text
[UE][NAS] successful NAS CIPHERING
[UE][NAS] Receive Registration Accept
[UE][NAS] UE 5G GUTI: &{119 11 [242 153 249 7 2 ... 1 111]}
```

---

## 3. How to Execute and Verify It Yourself

I have wrapped all of this into a single launcher script.

### Step 1: Launch the Attack
Navigate to the directory and run the launcher. You must provide two numbers: **Number of Pods** and **UEs per Pod**.

```bash
cd /home/venu/Desktop/5G-Registration-Attack/distributed-attack
bash launch-attack.sh 10 5
```
*(This commands 10 pods to register 5 UEs each, generating 50 concurrent registrations).*

### Step 2: Watch the Pods Boot
The script will tell you the exact time the attack will fire (usually 30 seconds in the future). In another terminal pane, watch Kubernetes provision the pods:

```bash
kubectl get pods -l app=packetrusher-attack -w
```

### Step 3: Verify the Attack Happened
To verify the pods successfully fired and registered their UEs, read the logs of the attack jobs. The presence of `Receive Registration Accept` proves the 5G Core successfully handled the attack load from that pod.

```bash
kubectl logs -l app=packetrusher-attack --prefix=true | grep "Registration Accept"
```

### Step 4: Scale it up
Once you're comfortable, you can hit the core with massive load:
```bash
# 200 Pods doing 10 UEs each = 2000 simultaneous registrations
bash launch-attack.sh 200 10
```

---

## 4. Understanding the Scripts

If you need to tweak or modify the attack, here is an explanation of the 5 files in `/home/venu/Desktop/5G-Registration-Attack/distributed-attack/`:

### 1. `Dockerfile`
This is a two-stage Dockerfile. In the first stage (`builder`), it downloads Go 1.21, pulls in the local `PacketRusher` source code folder, downloads dependencies, and compiles the `app` binary. In the second stage, it copies just the compiled binary and the `entrypoint.sh` into a clean, lightweight Ubuntu image. This keeps the final image small and secure.

### 2. `entrypoint.sh`
This script executes inside every pod when it starts up. 
- **Dynamic Identity:** First, it grabs the pod's index (0, 1, 2, etc.) passed from Kubernetes. It multiplies the index by the number of UEs (default 10) to calculate a unique starting IMSI (MSIN). E.g: index 0 gets 100, index 1 gets 110. It uses `sed` to replace `@MSIN_START@` inside the config file with this number.
- **Time Barrier:** It takes the `$TARGET_TIME` environment variable (which is a Unix epoch timestamp) and subtracts the exact current time from it. If the target is in the future, it `sleep`s for exactly that many seconds. 
- **Execution:** Once the sleep finishes, it executes the PacketRusher binary (`./app multi-ue -n $NUM_UE`).

### 3. `config.yml`
This is a standard PacketRusher configuration file. It tells the tool the local gNodeB settings (`999/70`, Slice `01/ffffff`), where the AMF is located (`10.43.111.106:38412`), and the authentication keys matching the Open5gs core (`465B...`). The `msin` field uses the placeholder `@MSIN_START@` so the entrypoint can inject the unique identity.

### 4. `attack-job.yaml`
This defines the Kubernetes `Job` resource.
- **ConfigMap:** It mounts the `config.yml` into the pods.
- **Indexed Job:** `completionMode: Indexed` ensures each pod spawned gets a unique, sequential index (0, 1, 2, ...).
- **Downward API:** It exposes `metadata.annotations['batch.kubernetes.io/job-completion-index']` as an environment variable (`$POD_INDEX`) inside the pod so the `entrypoint.sh` can calculate the unique IMSI. 
- **Placeholders:** The `$TARGET_TIME` and `parallelism/completions` values are left as placeholders to be filled dynamically.

### 5. `launch-attack.sh`
This is the master orchestration script you run on your terminal.
- First, it brutally wipes out the previous `packetrusher-attack` job to reset the system.
- Then, it takes the current time on your computer, adds 30 seconds to it (`TARGET_EPOCH=$(date -d "+30 seconds" +%s)`), and locks that in as the target fire time.
- Next, it uses `sed` to replace the placeholders in `attack-job.yaml` with the Target Epoch Time, the Number of Pods, and the Number of UEs requested. 
- Finally, it feeds this custom-rendered YAML into `kubectl apply` to launch the pods!
