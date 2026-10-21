# ai-fabric bastion: BIND9 for the lab zone (as reference), kubectl/helm/cilium CLI with the reference-style
# operator shell (KUBECONFIG + `k` alias + completion), sshd. Dual-homed LACP bond like the nodes.
# Built on eve: docker build --network host -t ai-fabric-bastion:refplat refplat/images/bastion
FROM ubuntu:24.04
ARG K8S_VERSION=v1.35.8
# Lab logins. Defaults are the containerlab convention (admin/admin); override with
# --build-arg, which build-images.sh does from LAB_ROOT_PASSWORD / LAB_ADMIN_PASSWORD in .env.
ARG LAB_ROOT_PASSWORD=admin
ARG LAB_ADMIN_PASSWORD=admin
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends locales \
      bind9 bind9-utils dnsutils chrony curl ca-certificates openssl iproute2 iputils-ping tcpdump traceroute socat \
      openssh-server sudo bash-completion vim-tiny less procps jq gettext-base net-tools lldpd \
 && locale-gen en_US.UTF-8 \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 20 -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl" \
 && chmod +x /usr/local/bin/kubectl \
 && curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 20 https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash \
 && CLI=$(curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 20 https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt) \
 && curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 20 -o /tmp/cilium-cli.tgz "https://github.com/cilium/cilium-cli/releases/download/${CLI}/cilium-linux-amd64.tar.gz" \
 && tar -xzf /tmp/cilium-cli.tgz -C /usr/local/bin && rm -f /tmp/cilium-cli.tgz \
 && mkdir -p /run/sshd /etc/bind/zones /var/opt/ai-fabric/clusters /workspace \
 && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/; s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
 && echo "root:${LAB_ROOT_PASSWORD}" | chpasswd \
 && useradd -m -s /bin/bash admin && echo "admin:${LAB_ADMIN_PASSWORD}" | chpasswd \
 && echo 'admin ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/admin
COPY bastion-init.sh /usr/local/bin/bastion-init.sh
COPY bastion-dns.sh /usr/local/bin/bastion-dns.sh
COPY lldpd.conf /etc/lldpd.d/ai-fabric.conf
COPY operator-shell.sh /etc/profile.d/operator-shell.sh
COPY authorized_keys /root/.ssh/authorized_keys
RUN chmod +x /usr/local/bin/bastion-init.sh /usr/local/bin/bastion-dns.sh \
 && chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys \
 && mkdir -p /home/admin/.ssh && cp /root/.ssh/authorized_keys /home/admin/.ssh/ \
 && chown -R admin:admin /home/admin/.ssh && chmod 700 /home/admin/.ssh \
 && echo '. /etc/profile.d/operator-shell.sh' >> /etc/bash.bashrc
ENTRYPOINT ["/usr/local/bin/bastion-init.sh"]
