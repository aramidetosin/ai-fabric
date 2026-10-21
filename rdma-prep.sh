#!/bin/bash
# rdma-prep.sh [node ...]: SoftRoCE prerequisites on the GPU nodes (NVIDIA network-operator lab, site-a-nx, operator decisions 2026-09-24).
#   linux-modules-extra-<running kernel>  rdma_rxe (the in-box SoftRoCE driver; the generic image ships it only in the extra modules)
#   rdma-core ibverbs-providers           the RDMA userspace, librxe included
#   ibverbs-utils perftest                ibv_devices / ibv_devinfo and ib_write_bw for the SoftRoCE probe (rdma-probe.sh)
# Installs only what is missing (apt through the firewall), then re-runs netsetup.sh, which loads mlx5_core + rdma_rxe and creates rxe_gpuN on every
# rail NIC -- and does that again at every boot, so the devices persist. finish.sh runs this (profile service network-operator) before netop.sh.
#   CHECK=1   only report: packages, rxe devices per rail NIC, mlx5_core loaded, rdma_cm present, no rxe device with its GSI QP (QP1) in ERR
cd "$(dirname "$0")"; . ./lib.sh
python3 -c 'import gen,sys; sys.exit(0 if gen.NETOP else 1)' || { echo "rdma-prep: no network-operator in this profile"; exit 0; }
read -r RAILS GPUS <<< "$(python3 -c 'import gen; print(gen.RAILS, " ".join(n for n, h in gen.HOSTS.items() if h.get("kind") == "gpu"))')"
NODES=${*:-$GPUS}; OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
PK='linux-modules-extra-$(uname -r) rdma-core ibverbs-providers ibverbs-utils perftest'
L() { timeout 900 ssh -n $SSHO "admin@$(mgmt "$1")" "sudo sh -c '$2'" 2>&1; }      # like H, with room for apt (H stops after 120 s)
state='miss=; for p in '"$PK"'; do dpkg -s $p >/dev/null 2>&1 || miss="$miss $p"; done
       rxe=$(rdma link show 2>/dev/null | grep -c "link rxe_gpu"); mlx=$(lsmod | grep -q "^mlx5_core" && echo loaded || echo missing)
       [ -e /dev/infiniband/rdma_cm ] || mlx="$mlx,rdma_cm-missing"
       e=$(rdma res show qp 2>/dev/null | grep "type GSI state ERR" | grep -o "rxe_gpu[0-9]*" | tr "\n" " "); [ -n "$e" ] && mlx="$mlx,QP1-ERR:${e% }"'
one() { local n=$1 o
  if [ -z "${CHECK:-}" ]; then
    o=$(L "$n" "$state"'
      if [ -n "$miss" ]; then export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -q $miss >/tmp/rdma-prep.log 2>&1 || { apt-get update -q >>/tmp/rdma-prep.log 2>&1; apt-get install -y -q $miss >>/tmp/rdma-prep.log 2>&1; } \
          || { echo "APT-FAILED:$miss $(tail -1 /tmp/rdma-prep.log)"; exit 1; }
        echo "installed:$miss"; fi
      systemctl restart ai-fabric-netsetup; '"$state"'; echo "pkgs-missing=${miss:-none} rxe=$rxe mlx5_core=$mlx"')
  else o=$(L "$n" "$state"'; echo "pkgs-missing=${miss:-none} rxe=$rxe mlx5_core=$mlx"'); fi
  echo "$n $(echo "$o" | tail -2 | paste -sd' ')"
}
for n in $NODES; do one "$n" > "$OUT/$n" & done; wait
cat "$OUT"/* | sort -V | sed 's/^/   /'
ok=$(cat "$OUT"/* | grep -c "pkgs-missing=none rxe=$RAILS mlx5_core=loaded$")
echo "rdma-prep: $ok/$(echo $NODES | wc -w) GPU nodes with every package, $RAILS SoftRoCE devices (QP1 healthy), rdma_cm and mlx5_core"
[ "$ok" = "$(echo $NODES | wc -w)" ]
