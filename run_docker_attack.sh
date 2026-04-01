set -e

echo "Stopping and removing previous containers..."
sudo docker ps -a | grep packetrusher- | awk '{print $1}' | xargs -r sudo docker rm -f

PODS=10
UES_PER_POD=100
BARRIER_WAIT=65

NOW=$(date +%s)
TARGET_EPOCH=$((NOW + BARRIER_WAIT))
echo "Target fire time: $(date -d @$TARGET_EPOCH) (epoch: $TARGET_EPOCH)"

for i in $(seq 0 $((PODS-1))); do
    echo "Starting attacker $i..."
    sudo docker run -d --name packetrusher-$i \
        --network host \
        --privileged \
        -e POD_INDEX=$i \
        -e NUM_UE=$UES_PER_POD \
        -e HOST_IP=127.0.0.1 \
        -e NUM_GNB_PER_POD=4 \
        -e AMF_IPS=127.0.0.1 \
        -e TARGET_TIME=$TARGET_EPOCH \
        packetrusher-attack:v20
done

echo ""
echo "All containers will fire synchronously at $(date -d @$TARGET_EPOCH)"
echo "Monitor with: sudo docker logs -f packetrusher-0"
