#!/bin/bash
# node-sync.sh [node ...]: keep what the guests run AT EVERY BOOT equal to this repository. cloud-init writes these files once, at a guest's
# first boot; a fix made here later would otherwise never reach an existing disk, and the next guest reboot would bring the old behaviour back.
#   every guest : netsetup.sh, ai-fabric-netsetup.service, ai-fabric-cluster.service, networkd drop-in (foreign rules/routes are left alone)
#   init node   : cluster-bootstrap.sh + the manifests it applies (the init node re-runs the bootstrap at every boot)
#   storage     : the storage management API unit + the management-VIP unit and their scripts (fb-api-start.sh, fb-vip.sh)
#   every guest : /etc/ai-fabric/node.env = what its container rendered at this start (/vm/user-data). cloud-init writes node.env only at a guest's
#                 FIRST boot, so a changed value (site-a-nx: data VLAN 10 -> 100, DNS/NTP -> dns-b, storage management on VLAN 200) would
#                 otherwise never reach an existing disk.
# A guest whose network files changed gets them applied live (networkd restart + netsetup re-run; both idempotent, no link flap).
# CHECK=1 only reports. NET_ONLY=1 leaves the init node's bootstrap files alone (network files only). Exit 3 = the init node's bootstrap files changed (finish.sh re-runs the bootstrap), 0 = in sync / synced, 1 = failure.
cd "$(dirname "$0")"; . ./lib.sh
INIT=ctrl1; SRC=images/vm-node/node-files; NODES=${*:-$CTRLS storage $GPUS}; OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT; mkdir -p "$OUT/env"   # node.env copies apart from the per-guest reports (the summary cats "$OUT"/*)
MAP="netsetup.sh=/usr/local/bin/netsetup.sh ai-fabric-netsetup.service=/etc/systemd/system/ai-fabric-netsetup.service ai-fabric-cluster.service=/etc/systemd/system/ai-fabric-cluster.service networkd-foreign.conf=/etc/systemd/networkd.conf.d/10-ai-fabric-foreign.conf lldpd-ai-fabric.conf=/etc/lldpd.d/ai-fabric.conf"
one() { local n=$1 ip map f dst src want have mode net=0 boot=0 lldp=0 fb=0; ip=$(mgmt "$n"); map=$MAP
  [ "$n" = storage ] && map="$map flashblade-api.service=/etc/systemd/system/flashblade-api.service fb-vip.service=/etc/systemd/system/fb-vip.service tools/fb-api-start.sh=/usr/local/bin/fb-api-start.sh tools/fb-vip.sh=/usr/local/bin/fb-vip.sh"
  [ "$n" = $INIT ] && [ -z "${NET_ONLY:-}" ] && { map="$map cluster-bootstrap.sh=/usr/local/bin/cluster-bootstrap.sh"; for f in $SRC/k8s/*; do [ -f "$f" ] && map="$map k8s/${f##*/}=/opt/ai-fabric/k8s/${f##*/}"; done; }
  S() { timeout 90 ssh $SSHO "admin@$ip" "$@"; }
  # node.env as the container rendered it at this start (the NODE_ENV_B64 entry of /vm/user-data)
  docker exec "$LAB-$n" cat /vm/user-data 2>/dev/null | sed -n 's|.*path: /etc/ai-fabric/node.env,.*content: "\([^"]*\)".*|\1|p' | base64 -d > "$OUT/env/$n.env" 2>/dev/null
  remote=$(S -n "sudo sha256sum $(for m in $map; do printf '%s ' "${m#*=}"; done) 2>/dev/null; true") || { echo "$n UNREACHABLE"; return; }
  for m in $map; do f=${m%%=*}; dst=${m#*=}; src="$SRC/$f"
    want=$(sha256sum < "$src" | cut -d' ' -f1); have=$(awk -v d="$dst" '$2 == d {print $1}' <<< "$remote")
    [ "$want" = "$have" ] && continue
    case $f in cluster-bootstrap.sh|k8s/*) boot=1 ;; lldpd-*.conf) lldp=1 ;; flashblade-api.service|fb-vip.service|tools/fb-*) fb=1 ;; *) net=1 ;; esac
    [ -n "${CHECK:-}" ] && { echo "$n DRIFT $dst"; continue; }
    mode=644; [ "${f##*.}" = sh ] && mode=755
    S "sudo mkdir -p ${dst%/*} && sudo tee $dst >/dev/null && sudo chmod $mode $dst" < "$src" && echo "$n UPDATED $dst" || { echo "$n FAILED $dst"; return; }
  done
  # node.env compared SORTED: env lists variables in a different order in every container, the values are what matters (checked 2026-09-23)
  if [ -s "$OUT/env/$n.env" ]; then LC_ALL=C sort "$OUT/env/$n.env" > "$OUT/env/$n.env.s"
    if [ "$(sha256sum < "$OUT/env/$n.env.s" | cut -d' ' -f1)" != "$(S -n "sudo env LC_ALL=C sort /etc/ai-fabric/node.env 2>/dev/null | sha256sum" | cut -d' ' -f1)" ]; then
      if [ -n "${CHECK:-}" ]; then echo "$n DRIFT /etc/ai-fabric/node.env"
      else S "sudo tee /etc/ai-fabric/node.env >/dev/null && sudo chmod 600 /etc/ai-fabric/node.env" < "$OUT/env/$n.env.s" && { echo "$n UPDATED /etc/ai-fabric/node.env"; net=1; fb=1; } || { echo "$n FAILED /etc/ai-fabric/node.env"; return; }; fi
    fi
  fi
  [ -z "${CHECK:-}" ] && [ $lldp = 1 ] && { S -n "sudo systemctl enable --now lldpd; sudo systemctl restart lldpd" >/dev/null 2>&1 && echo "$n APPLIED lldpd config" || echo "$n FAILED lldpd apply"; }
  [ -z "${CHECK:-}" ] && [ $net = 1 ] && { S -n "sudo systemctl daemon-reload; sudo systemctl restart systemd-networkd; sudo systemctl restart ai-fabric-netsetup" >/dev/null 2>&1 && echo "$n APPLIED network files live" || echo "$n FAILED live apply"; }
  [ -z "${CHECK:-}" ] && [ "$n" = storage ] && [ "${fb:-0}" = 1 ] && { S -n "sudo systemctl daemon-reload; sudo systemctl enable fb-vip.service flashblade-api.service >/dev/null 2>&1; sudo systemctl restart fb-vip.service flashblade-api.service" >/dev/null 2>&1 && echo "$n APPLIED storage management units" || echo "$n FAILED storage management units"; }
  [ $boot = 1 ] && echo "$n BOOTSTRAP-CHANGED"; echo "$n done"
}
for n in $NODES; do one "$n" > "$OUT/$n" 2>&1 & done; wait
cat "$OUT"/* 2>/dev/null | grep -v " done$" | sort -V
total=$(echo $NODES | wc -w); okc=$(cat "$OUT"/* 2>/dev/null | grep -c " done$"); bad=$(cat "$OUT"/* 2>/dev/null | grep -cE "UNREACHABLE|FAILED|DRIFT")
[ "$okc" = "$total" ] && [ "$bad" = 0 ] && ! grep -sqh "UPDATED\|BOOTSTRAP-CHANGED" "$OUT"/* && { echo "node-sync: $total/$total guests in sync with the repository"; exit 0; }
[ "$bad" != 0 ] || [ "$okc" != "$total" ] && { echo "node-sync: $bad problem(s), $okc/$total guests processed"; exit 1; }
echo "node-sync: $total/$total guests synced"; grep -sqh "BOOTSTRAP-CHANGED" "$OUT"/* && exit 3; exit 0
