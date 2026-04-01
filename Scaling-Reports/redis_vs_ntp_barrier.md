# Synchronization: Time Barrier vs. Redis

When trying to synchronize 200 pods to execute a network attack (like a 5G registration storm) at the *exact* same millisecond, you have two primary choices: a **Time Barrier (NTP)** or a **Message Broker (Redis Pub/Sub)**.

Here is a breakdown of why the **Time Barrier (NTP)** approach is generally considered better and more robust for this specific load-generation use-case.

## 1. Time Barrier (NTP Epoch Scheduling)

**How it works**
You calculate a time in the future (e.g., `T + 60s`). You pass this timestamp to 200 pods. They all wake up, look at their local system clock, sleep exactly until that timestamp, and then fire.

✅ **Pros:**
- **Zero Dependencies:** You don't need to deploy, configure, or maintain a Redis cluster. Your cluster only needs its standard NTP daemon (which Kubernetes nodes always have).
- **Zero Network Jitter:** Because the pods aren't waiting for a network packet to arrive before firing, there is no network latency jitter. They all fire based on their internal CPU clocks simultaneously. 
- **Simplicity:** It's just a 5-line bash script.
- **Perfect Scalability:** Whether it’s 200 pods or 20,000 pods, the synchronization logic scales perfectly because it's completely decentralized. 

❌ **Cons:**
- **Fixed Start Time:** You have to guess how long it will take all 200 pods to reach the `Running` state (e.g., padding the start time by 60-90 seconds). If the cluster is slow and a pod takes 91 seconds to pull the image and start, that pod will miss the synchronized barrage and fire late.
- **No Cancel Button:** Once the pods start sleeping toward the target time, it's difficult to cleanly abort them simultaneously without deleting the whole Kubernetes Job.

## 2. Redis Pub/Sub (The Starter Pistol)

**How it works**
All 200 pods start up, connect to a central Redis server, subscribe to a specific channel (e.g., `attack-channel`), and block. You manually publish a `START` message to that channel. As soon as the pods receive the message, they fire.

✅ **Pros:**
- **Flexible Timing:** You don't have to guess when the pods will be ready. You can verify that all 200 are online, and *then* press the button.
- **Abort Capability:** You can choose to never send the `START` message, or send an `ABORT` message instead.

❌ **Cons:**
- **Network Latency/Jitter:** Sending a message to 200 subscribers over a network inherently introduces micro-delays. Pod #1 might receive the packet a few milliseconds before Pod #200. In high-frequency network flooding, this jitter can dilute the "spike" you are trying to create against the 5G core.
- **Dependency Overhead:** You now have to deploy and manage a highly available Redis instance in your cluster. If the Redis server crashes under the connection load of the pods booting up, the test fails.
- **Code Complexity:** Your Docker image needs a scripting runtime (Python, Go, Node) and Redis client libraries installed, rather than a simple bash command.

---

### Verdict

For a **5G Registration Attack**, the goal is usually to create an *instantaneous, massive* spike in Control Plane messaging (N1/N2 interfaces) to overwhelm the AMF/SMF. 

Because maximum concurrency and zero-jitter are the most important factors for this kind of DDoS / load testing simulation, **the NTP Time Barrier is the superior approach**. It guarantees that all 200 processes issue their system calls at the precise same millisecond, without relying on network packet delivery to pull the trigger.
