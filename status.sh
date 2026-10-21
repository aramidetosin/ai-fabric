#!/bin/bash
# One-screen status of ai-fabric: switch health, guest boot stage, Kubernetes nodes. Run on eve: ./status.sh
cd "$(dirname "$0")"; . ./lib.sh
echo "== switches/firewall: $(for n in $FE_SPINES $FE_LEAVES $FE_BORDERS oob-sw $BE_SPINES $BE_LEAVES fw; do health $n; done | sort | uniq -c | tr '\n' ' ')"
echo "== guests (cloud-init | default route | last bootstrap line)"
for n in $CTRLS storage $GPUS; do
  c=nodes/$n/vm/console.log
  ci=$(grep -c "VM node ready\|Cloud-init.*finished" $c 2>/dev/null); ci=$([ "${ci:-0}" -gt 0 ] && echo done || echo running)
  rt=$(H $n "ip route show default | head -1 | cut -d\" \" -f3-5" 2>/dev/null | head -1)
  bs=$(H $n "journalctl -u ai-fabric-cluster --no-pager -o cat 2>/dev/null | tail -1" 2>/dev/null | cut -c1-110)
  printf "  %-8s %-8s %-22s %s\n" "$n" "$ci" "${rt:-no-ssh-yet}" "$bs"
done
echo "== kubernetes"; K "kubectl get nodes -o wide --no-headers 2>/dev/null | awk '{print \$1, \$2, \$3, \$6}' | column -t" | head -14
