#!/bin/bash
# harbor-trust.sh [node ...]: containerd on the nodes (a) trusts the cluster CA for https://harbor.platform.lab.ai and (b) pulls docker.io, quay.io,
# ghcr.io and registry.k8s.io through Harbor's proxy-cache projects first, then through the host's pull-through cache when the profile has one,
# then from the upstream. hosts.toml is read on every pull: no containerd restart. Idempotent.
#
# It also normalises the CRI registry config_path. containerd 2.2 IGNORES hosts.toml entirely when config_path is the packaged
# two-directory default '/etc/containerd/certs.d:/etc/docker/certs.d' -- the pull then goes straight upstream and Harbor never sees it
# (found on site-a 2026-09-20: every node had correct hosts.toml, yet the proxy-cache projects and the S3 blob bucket stayed empty).
# A single directory works. That one IS read at startup, so a node whose config_path changed gets containerd restarted -- serialised,
# one node at a time, waiting for the node to come back Ready, because restarting all 39 at once is not worth the risk.
cd "$(dirname "$0")"; . ./lib.sh
NODES=${*:-$CTRLS storage $GPUS}; MIRRORS=$(python3 -c 'import gen; print(gen.PF["mirrors"])')
declare -A PRJ=([docker.io]=proxy-dockerhub [quay.io]=proxy-quay [ghcr.io]=proxy-ghcr [registry.k8s.io]=proxy-k8s [nvcr.io]=proxy-nvcr) UP=([docker.io]=https://registry-1.docker.io [quay.io]=https://quay.io [ghcr.io]=https://ghcr.io [registry.k8s.io]=https://registry.k8s.io [nvcr.io]=https://nvcr.io)
S=$(mktemp); { echo 'set -e; D=/etc/containerd/certs.d; H=harbor.platform.lab.ai; mkdir -p $D/$H; cp /shared/ai-fabric/cluster-ca.crt $D/$H/ca.crt'
  echo 'printf "server = \"https://%s\"\n\n[host.\"https://%s\"]\n  capabilities = [\"pull\", \"resolve\", \"push\"]\n  ca = \"%s/%s/ca.crt\"\n" $H $H $D $H > $D/$H/hosts.toml'
  for r in "${!PRJ[@]}"; do m=$(for x in $MIRRORS; do [ "${x%%=*}" = "$r" ] && echo "${x#*=}"; done)
    echo "mkdir -p \$D/$r; { printf 'server = \"${UP[$r]}\"\n\n[host.\"https://'\$H'/v2/${PRJ[$r]}\"]\n  capabilities = [\"pull\", \"resolve\"]\n  override_path = true\n  ca = \"'\$D/\$H'/ca.crt\"\n'"
    [ -n "$m" ] && echo "  printf '\n[host.\"$m\"]\n  capabilities = [\"pull\", \"resolve\"]\n'"
    echo "} > \$D/$r/hosts.toml"; done
  # the config_path fix: only a value that lists /etc/containerd/certs.d among several directories is rewritten, so
  # plugin_config_path and the unrelated empty config_path further down the file are left exactly as they are
  cat <<'SH'
C=/etc/containerd/config.toml
if grep -qE "^[[:space:]]*config_path[[:space:]]*=[[:space:]]*['\"][^'\"]*/etc/containerd/certs\.d[^'\"]*:" "$C"; then
  cp -n "$C" "$C.bak-cfgpath" 2>/dev/null || true
  sed -i -E "s#^([[:space:]]*config_path[[:space:]]*=[[:space:]]*)['\"][^'\"]*/etc/containerd/certs\.d[^'\"]*['\"]#\1'/etc/containerd/certs.d'#" "$C"
  echo CONFIG_PATH_CHANGED
fi
SH
  echo 'echo ok'; } > "$S"
for n in $NODES; do ( o=$(HS $n "$S"); if [ "$(echo "$o" | tail -1)" = ok ]
    then echo "$n ok$(echo "$o" | grep -q CONFIG_PATH_CHANGED && echo ' cfgpath')"
    else echo "$n FAILED: $(echo "$o" | tail -1)"; fi ) & done | sort -V > "$S.out"; wait
echo "containerd trust + proxy-cache mirrors: $(grep -c ' ok' "$S.out")/$(echo $NODES | wc -w) nodes"; grep FAILED "$S.out" || true
CH=$(awk '/cfgpath/ {print $1}' "$S.out")
if [ -n "$CH" ]; then echo "config_path normalised on $(echo $CH | wc -w) node(s); restarting containerd one at a time"
  for n in $CH; do H "$n" "systemctl restart containerd" >/dev/null 2>&1
    a=; for i in $(seq 1 30); do a=$(H "$n" "systemctl is-active containerd" 2>/dev/null | tail -1); [ "$a" = active ] && break; sleep 2; done
    K "kubectl wait --for=condition=Ready node/$n --timeout=180s" >/dev/null 2>&1 \
      && echo "  $n containerd $a, node Ready" || echo "  $n containerd $a, node NOT Ready within 180 s"
  done
fi
rm -f "$S" "$S.out"
