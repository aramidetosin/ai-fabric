#!/bin/sh
# registry-mirrors.sh: point containerd at pull-through caches. REGISTRY_MIRRORS="docker.io=http://host:5001 quay.io=http://host:5002 ..."
# (set per profile in gen.py; empty = pull straight from the internet). containerd falls back to the upstream when a cache does not answer.
[ -n "${REGISTRY_MIRRORS:-}" ] || exit 0
# containerd 2.2: the CRI default "/etc/containerd/certs.d:/etc/docker/certs.d" (two directories) never consults hosts.toml; a single
# directory does (found 2026-09-18: pulls bypassed the cache until this was changed). plugin_config_path is left alone (anchored match).
sed -i -E "s#^( *config_path = ).*#\\1\"/etc/containerd/certs.d\"#" /etc/containerd/config.toml
for m in $REGISTRY_MIRRORS; do reg=${m%%=*}; url=${m#*=}; up="https://$reg"; [ "$reg" = docker.io ] && up="https://registry-1.docker.io"
  mkdir -p "/etc/containerd/certs.d/$reg"
  printf 'server = "%s"\n\n[host."%s"]\n  capabilities = ["pull", "resolve"]\n' "$up" "$url" > "/etc/containerd/certs.d/$reg/hosts.toml"; done
systemctl restart containerd
