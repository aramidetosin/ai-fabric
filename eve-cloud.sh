#!/bin/bash
# eve-cloud.sh: join an EVE-NG cloud bridge (profile key eve_cloud, site-b: pnet5) to this lab's management network with a veth pair, so EVE-NG
# nodes attached to that cloud sit in 172.21.21.0/24 next to the switches' management ports (an NMS or controller VM in its own EVE lab).
# containerlab recreates the management bridge (new name) at every deploy: up.sh and finish.sh call this each time. Idempotent.
cd "$(dirname "$0")"; PNET=$(python3 -c 'import gen; print(gen.PF["eve_cloud"])'); [ -n "$PNET" ] || exit 0
NET=$(python3 -c 'import gen; print(gen.MGMT_NET)'); id=$(docker network inspect "$NET" -f '{{.Id}}' 2>/dev/null) || { echo "eve-cloud: docker network $NET not there yet"; exit 1; }
BR=$(docker network inspect "$NET" -f '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null); [ -n "$BR" ] && [ "$BR" != "<no value>" ] || BR=br-${id:0:12}
[ -d /sys/class/net/$PNET/bridge ] || { echo "eve-cloud: EVE bridge $PNET does not exist"; exit 1; }
ip link show ai-fabric-eve0 >/dev/null 2>&1 || ip link add ai-fabric-eve0 type veth peer name ai-fabric-eve1
ip link set ai-fabric-eve0 master "$PNET"; ip link set ai-fabric-eve1 master "$BR"; ip link set ai-fabric-eve0 up; ip link set ai-fabric-eve1 up
echo "eve-cloud: $PNET <-> $BR ($NET): $(cat /sys/class/net/ai-fabric-eve0/operstate)/$(cat /sys/class/net/ai-fabric-eve1/operstate)"
