#!/bin/bash
# build-images.sh: the two local images of the lab (refplat's vm-node + real rail NICs + registry-mirror hook; refplat's bastion).
set -euo pipefail
cd "$(dirname "$0")"
[ -s common/authorized_keys ] || { echo "common/authorized_keys is empty: add the operator public keys first"; exit 1; }
grep -q "$(cut -d' ' -f2 /root/.ssh/id_ed25519.pub)" common/authorized_keys || { echo "this host's root key (/root/.ssh/id_ed25519.pub) is not in common/authorized_keys"; exit 1; }
docker build --network host -t ai-fabric-vm-node:latest images/vm-node
cp common/authorized_keys images/bastion/authorized_keys
docker build --network host \
  --build-arg LAB_ROOT_PASSWORD="${LAB_ROOT_PASSWORD:-admin}" \
  --build-arg LAB_ADMIN_PASSWORD="${LAB_ADMIN_PASSWORD:-admin}" \
  -t ai-fabric-bastion:latest images/bastion
