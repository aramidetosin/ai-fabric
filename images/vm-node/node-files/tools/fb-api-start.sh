#!/bin/sh
# fb-api-start.sh: start the storage management API stand-in on the management VIP (site-a-nx: VLAN 200, NODE_SM_VIP, moved between FM1/FM2 by
# fb-vip.sh) or on the OOB address (other profiles). Reads /etc/ai-fabric/node.env, so node-sync changing that file re-targets the API.
. /etc/ai-fabric/node.env
BIND=${NODE_SM_VIP:-${OOB_IP:-}}; [ -n "$BIND" ] || { echo "fb-api: no management address in node.env"; exit 1; }
until ip -4 -o addr show | grep -q " $BIND/"; do sleep 2; done      # the socket binds the address, whichever NIC holds it now
exec /usr/bin/python3 /usr/local/bin/fb-api.py --bind "$BIND" --port 443 --cert /etc/ai-fabric/fb/cert.pem --key /etc/ai-fabric/fb/key.pem \
  --kubeconfig "/shared/${CLUSTER_NAME:-refplat}/kubeconfig" --token "${FB_TOKEN:-lab-storage-api-token}"
