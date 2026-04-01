# Ultimate 1000-UE Standalone Benchmark Guide

## The Constraint: IIT Delhi Network Hardware
Extensive TCP-dump diagnostic tests have proved that attempting to run a distributed attack across two campus machines fails at the physical layer. The managed campus Ethernet switches enforce **Deep Packet Inspection (DPI)**, selectively discarding Layer-4 `SCTP` (Protocol 132) packets required for 5G NGAP signaling. 

Because of this physical hardware constraint, **all multi-node approaches routing through the wall ports will fail**.

## The Solution: Local Standalone Execution
The definitive solution to bypassing the hardware constraint while achieving a 100% capacity benchmark is to execute the **Open5GS Core** and the **1000-UE PacketRusher generators** symmetrically on the **16-core machine**, isolated from the external network logic.

### Deployment Bundle
To eliminate external dependencies (Network API timeouts, Wi-Fi proxy limits, etc), the execution sequence has been natively wrapped into Docker containers and packaged into a self-contained bundle.

**Location (on 8-Core PC):** `~/Desktop/5G-Registration-Attack/16-Core-Docker-Bundle/`

Included Assets:
1. `packetrusher.tar`: Natively exported Docker image (78 MB).
2. `config.yml`: Core target configuration (bound iteratively to localized AMF `127.0.0.1`).
3. `run_docker_attack.sh`: The automated 10-pod synchronized launch logic script.

### Execution Procedure (On the 16-Core Machine)

1. Obtain local or remote terminal access to the 16-core processing unit.
2. Transfer the bundle (`cp`, `scp`, or `usb`) into the target machine.
3. Simply execute the wrapper script:
   ```bash
   cd 16-Core-Docker-Bundle
   bash run_docker_attack.sh
   ```

The script will:
- Silently initialize the Docker `packetrusher-attack:v19` image with zero internet requirement.
- Calculate a synchronized NTP execution `TARGET_TIME`.
- Immediately spawn 10 independent attacking processes natively mapped to the Host Network CPU context.
- Synchronously fire the 40 SCTP concurrent sockets directly onto the `127.0.0.1` AMF listener socket, effectively hitting the 1000-UE capacity benchmark natively without any packet drop interfaces.
