# ai-fabric VM node: a KVM Ubuntu guest wrapped in a container so containerlab can wire it like any other node.
# Used for the storage node: Longhorn's iSCSI initiator needs its own kernel network namespace, which a
# container node does not have. The guest is a stock Ubuntu 24.04 cloud image (bind-mounted, not baked)
# configured by cloud-init at first boot with the same node scripts as the container nodes.
# Built on eve: docker build --network host -t ai-fabric-vm-node:refplat refplat/images/vm-node
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      qemu-system-x86 qemu-utils cloud-image-utils genisoimage iproute2 bridge-utils iputils-ping procps \
      gettext-base ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
COPY vm-init.sh /usr/local/bin/vm-init.sh
COPY cloud-init/ /opt/cloud-init/
COPY node-files/ /opt/node-files/
RUN chmod +x /usr/local/bin/vm-init.sh
ENTRYPOINT ["/usr/local/bin/vm-init.sh"]
