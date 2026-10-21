#!/bin/bash
# finish.sh: from "containerlab deploy returned" to a FULLY WORKING lab with no hand steps. Idempotent; the same script finishes a first
# deployment (./down.sh wipe; ./up.sh), a redeploy that keeps the guest disks, and the automatic start after a host reboot (boot.sh).
#   1 switches + firewall healthy                     6 node classes and roles                     (roles.sh)
#   2 Kubernetes bootstrap finished on the init node  7 profile services: Harbor + S3 + Longhorn   (harbor-deploy.sh / harbor-trust.sh)
#   3 guests' boot-time files = this repository       8 every pod Running
#   4 every node Ready                                9 workstation kit, operator steps still open
#   5 fabric settled (east-west sweep, 3 clean rounds; repairs a stale ESI MAC by bouncing that node's links)
# Called by ./up.sh (skip with NO_FINISH=1). Log: finish.log. Exit status = number of failed stages.
set -uo pipefail
cd "$(dirname "$0")"
[ -n "${FINISH_INNER:-}" ] || { FINISH_INNER=1 "$0" "$@" 2>&1 | tee finish.log; exit "${PIPESTATUS[0]}"; }
. ./lib.sh
T0=$(date +%s); BAD=0; INIT=ctrl1; EXPECT=$(echo $CTRLS storage $GPUS | wc -w)
SERVICES=$(python3 -c 'import gen; print(gen.PF["services"])')
stage() { printf '\n== %s  [+%d min] %s\n' "$(date +%T)" $(( ($(date +%s) - T0) / 60 )) "$*"; }
fail()  { echo "   FAILED: $*"; BAD=$((BAD + 1)); }
G() { timeout 30 ssh -n $SSHO "admin@$(mgmt "$INIT")" "$@" 2>/dev/null; }          # quiet probe of the init node (no transcript)

# finished = the bootstrap unit ran to the end IN THIS BOOT of the guest and exited 0
bootstrap_done() { local st; st=" $(G 'systemctl show ai-fabric-cluster -p ActiveState -p ExecMainStatus -p ExecMainExitTimestampMonotonic' | xargs) "; [ "$st" != "  " ] || return 1
  [[ $st == *" ActiveState=inactive "* && $st == *" ExecMainStatus=0 "* && $st == *" ExecMainExitTimestampMonotonic="* && $st != *" ExecMainExitTimestampMonotonic=0 "* ]]; }
wait_bootstrap() { local i last="" l
  for i in $(seq 1 "${1:-240}"); do bootstrap_done && { echo "   bootstrap complete: $(G 'sudo tail -n 300 /var/log/ai-fabric-bootstrap.log' | grep '\[bootstrap' | tail -1)"; return 0; }
    l=$(G 'sudo tail -n 300 /var/log/ai-fabric-bootstrap.log' | grep '\[bootstrap' | tail -1); [ -n "$l" ] && [ "$l" != "$last" ] && { echo "   $l"; last=$l; }; sleep 30; done; return 1; }

stage "1/9 switches and firewall healthy"
./wait-switches.sh 120 | awk '/healthy/ || NR % 6 == 1' || fail "not every switch/firewall became healthy"

stage "2/9 Kubernetes bootstrap on $INIT (first deployment ~40 min at 39 nodes, a restart on existing disks ~10 min)"
wait_bootstrap 240 || fail "bootstrap did not finish within 2 h (ssh admin@$(mgmt $INIT) sudo tail /var/log/ai-fabric-bootstrap.log)"

stage "3/9 boot-time files on every guest = repository (node-sync.sh)"
./node-sync.sh | sed 's/^/   /'; rc=${PIPESTATUS[0]}
if [ $rc = 3 ]; then echo "   re-running the (idempotent) bootstrap with the updated files"; G 'sudo systemctl restart ai-fabric-cluster'; sleep 20; wait_bootstrap 120 || fail "bootstrap re-run did not finish"
elif [ $rc != 0 ]; then fail "node-sync"; fi
./cilium-devices.sh | sed 's/^/   /'; [ "${PIPESTATUS[0]}" = 0 ] || fail "cilium devices"      # a changed CILIUM_DEVICES never reaches a running cluster by itself

stage "4/9 $EXPECT nodes Ready"
for i in $(seq 1 90); do r=$(EVID= K "kubectl get nodes --no-headers 2>/dev/null | awk '\$2 == \"Ready\"' | wc -l" | tail -1); [ "${r:-0}" -ge "$EXPECT" ] && break; sleep 20; done
echo "   ${r:-0}/$EXPECT Ready"; [ "${r:-0}" -ge "$EXPECT" ] || fail "nodes not Ready: $(EVID= K "kubectl get nodes --no-headers | awk '\$2 != \"Ready\" {print \$1}' | xargs")"

stage "5/9 fabric settled: east-west + routed (enterprise PC) sweeps until three clean rounds in a row"
# "all nodes Ready" is not "every path forwards". Seen after a restart (2026-09-18): ONE vEX leaf kept a stale data-plane entry for ONE server's
# ESI MAC (control plane correct on every leaf) and silently dropped the flows hashed to it, for as long as nothing re-advertised that MAC.
# Every node pings six others per round (offsets move with the round; every ping process hashes to a bond leg of its own). A node that keeps
# showing up in the losses gets its fabric links bounced ONCE (8 s): EVPN withdraws and re-advertises its MAC and the leaves reprogram it.
mapfile -t NM < <(python3 -c 'import gen; [print(n, h["ip"]) for n, h in gen.HOSTS.items()]'); NN=${#NM[@]}; clean=0; badr=0; SW=$(mktemp -d); lost=""; fixed=" "; nveheal=""
declare -A NAME; for e in "${NM[@]}"; do NAME[${e#* }]=${e%% *}; done
for round in $(seq 1 40); do rm -f "$SW"/*
  for i in $(seq 0 $((NN - 1))); do read -r src _ <<< "${NM[$i]}"; tg=""
    for off in 1 5 11 17 23 29; do j=$(( (i + off + round) % NN )); [ "$j" = "$i" ] || tg="$tg ${NM[$j]#* }"; done
    ( timeout 60 ssh -n $SSHO "admin@$(mgmt "$src")" "for t in $tg; do ping -c 2 -W 1 -q \$t >/dev/null 2>&1 || echo $src \$t; done" > "$SW/$src" 2>/dev/null || echo "$src ssh" >> "$SW/$src" ) &
  done; wait
  # routed path too (enterprise PC -> firewall -> border leaves -> L3 VNI -> node): three ping processes per node = three flow hashes
  for e in "${NM[@]}"; do ( for k in 1 2 3; do docker exec "$LAB-pc-1" ping -c 1 -W 1 -q "${e#* }" >/dev/null 2>&1 || { echo "pc-1 ${e#* }"; break; }; done > "$SW/pc1-${e%% *}" ) & done; wait
  lost=$(cat "$SW"/* 2>/dev/null | while read -r a b; do echo "$a>${NAME[$b]:-$b}"; done | xargs)
  if [ -z "$lost" ]; then clean=$((clean + 1)); badr=0; [ $clean -ge 3 ] && break; continue; fi
  clean=0; badr=$((badr + 1)); echo "   round $round: no reply $(cut -c1-170 <<< "$lost")"
  # Nexus profiles, once: a vPC leaf whose nve1 does not decapsulate (control plane perfect, half of the pings to its pair's servers lost from everywhere,
  # site-a 2026-10-04) is found by its input counter and healed by an nve1 bounce: nx-nve-heal.sh. Before the per-node repair: that one cannot fix a leaf.
  if [ $badr -ge 2 ] && [ -z "$nveheal" ] && [ -f ./nx-nve-heal.sh ]; then nveheal=1; h=$(bash ./nx-nve-heal.sh 2>&1)
    [ -n "$h" ] && { sed 's/^/   repair: /' <<< "$h"; badr=0; sleep 15; continue; }; fi
  if [ $badr -ge 2 ]; then   # the node named most often (at least twice), not repaired before
    read -r cnt who <<< "$(tr ' >' '\n\n' <<< "$lost" | grep -v '^ssh$' | sort | uniq -c | sort -rn | head -1)"
    if [ "${cnt:-0}" -ge 2 ] && [[ $fixed != *" $who "* ]] && [ $(wc -w <<< "$fixed") -lt 4 ]; then fixed="$fixed$who "
      echo "   repair: $who is in $cnt lost pairs -> bouncing its fabric links (8 s) so EVPN re-advertises its MAC"
      timeout 60 ssh -n $SSHO "admin@$(mgmt "$who")" "sudo sh -c 'ip link set eth1 down; ip link set eth2 down; sleep 8; ip link set eth1 up; ip link set eth2 up'" >/dev/null 2>&1; sleep 15; badr=0
    fi
  fi; sleep 15
done; rm -rf "$SW"
[ $clean -ge 3 ] && echo "   settled after $round round(s): $((NN * 6)) node pairs + $NN routed paths per round, no loss${fixed:+   (repaired:$fixed)}" | sed 's/(repaired: )//' || fail "east-west still losing: $lost"

stage "6/9 node classes and roles$(python3 -c 'import gen; print(" + lab CA certificates" if gen.LAB_CA else "")')"
./roles.sh | sed 's/^/   /'
# lab CA (site-a-nx): storage API + firewall UI certificates from the Platform CA; the storage one goes onto the storage node
./ca-certs.sh | sed 's/^/   /'; [ "${PIPESTATUS[0]}" = 0 ] || fail "lab CA certificates (ca-certs.sh)"

stage "7/9 profile services: ${SERVICES:-none}"
if [[ " $SERVICES " == *" harbor "* ]]; then
  if [ "$(EVID= K "helm -n harbor status harbor -o json 2>/dev/null | jq -r .info.status" | tail -1)" = deployed ]; then
    echo "   Harbor release already deployed: waiting for S3 + Harbor to be available again, then refreshing containerd trust"
    KT=1900 K "kubectl -n s3 rollout status deploy/minio --timeout=900s | tail -1; kubectl -n harbor wait --for=condition=Available deploy --all --timeout=900s | sed 's/^/   /'" || fail "Harbor/S3 not available"
    # the proxy-cache projects again (idempotent: an existing registry/project answers 409), so one added later (proxy-nvcr, 2026-09-24) reaches a running Harbor
    docker cp harbor/harbor-projects-job.yaml "$LAB-bastion:/tmp/harbor-projects-job.yaml" >/dev/null
    KT=960 K "kubectl -n harbor delete job harbor-proxy-projects --ignore-not-found >/dev/null; kubectl apply -f /tmp/harbor-projects-job.yaml >/dev/null; kubectl -n harbor wait --for=condition=complete job/harbor-proxy-projects --timeout=900s >/dev/null; kubectl -n harbor logs job/harbor-proxy-projects | grep -v waiting | tail -1" | sed 's/^/   projects: /' || fail "Harbor proxy-cache projects"
    ./harbor-trust.sh | sed 's/^/   /'
  else ./harbor-deploy.sh | sed 's/^/   /' || fail "harbor-deploy.sh"; fi
fi

if [[ " $SERVICES " == *" network-operator "* ]]; then   # site-a-nx: the production GPU cluster's NVIDIA network-operator stack (operator 2026-09-24)
  ./rdma-prep.sh | sed 's/^/   /'; [ "${PIPESTATUS[0]}" = 0 ] || fail "SoftRoCE prerequisites on the GPU nodes (rdma-prep.sh)"
  ./netop.sh | sed 's/^/   /'; [ "${PIPESTATUS[0]}" = 0 ] || fail "network-operator stack (netop.sh)"
fi

stage "8/9 every pod Running"
for i in $(seq 1 90); do p=$(EVID= K "kubectl get pods -A --no-headers 2>/dev/null | awk '\$4 != \"Running\" && \$4 != \"Completed\" {print \$1\"/\"\$2\"(\"\$4\")\"}' | xargs" | tail -1)
  # Open WebUI stays in Init until the operator has created its OpenRouter secret: not a fault of the deployment
  # the model pods in ai-sim are looked after below (llm-serve.sh): a server started with rail addresses its workers no longer hold restarts until then
  p=$(tr ' ' '\n' <<< "$p" | grep -v -E '^(webui|ai-sim)/' | xargs); [ -z "$p" ] && break
  # a Longhorn instance-manager pod left from before the restart can stay Pending for ever (restartPolicy Never: the kubelet does not start it again, and
  # Longhorn waits for it, CR state "starting"); once deleted Longhorn creates a new one (site-a 2026-10-04: six, on nodes that rejoined through a lossy leaf)
  [ "$i" = 9 ] && grep -q 'longhorn-system/instance-manager-[^ ]*(Pending)' <<< "$p" && { echo "   repair: Longhorn instance-manager pod(s) still Pending after 3 min -> deleted, Longhorn recreates them"
    EVID= K "kubectl -n longhorn-system get pods --no-headers | awk '\$1 ~ /^instance-manager-/ && \$3 == \"Pending\" {print \$1}' | xargs -r kubectl -n longhorn-system delete pod --wait=false" >/dev/null 2>&1; }
  sleep 20; done
[ -z "$p" ] && echo "   all pods Running" || fail "pods not Running: $p"

stage "9/9 workstation kit + operator steps"
# the lab's language model on the GPU nodes (two replicas, RPC workers over rails 3 and 6): also the local model of the inference gateway. Only when it
# has been deployed before (the image is on the nodes); a rail that does not forward must not fail a boot, so this is a warning, not a stage of its own
if EVID= K "kubectl get ns ai-sim >/dev/null 2>&1 && echo yes" | grep -q yes; then ./llm-serve.sh up 2>&1 | tail -1 | sed 's/^/   /'; [ "${PIPESTATUS[0]}" = 0 ] || echo "   WARNING: the model on the GPU nodes is not serving (./llm-serve.sh up once the rails forward: ./rail-heal.sh)"; fi
./eve-cloud.sh 2>&1 | sed 's/^/   /'
# SNMP v2c for Weft: the switches carry it in their generated configs; the servers, the bastion and the PCs get snmpd here after every deploy
./snmp-enable.sh servers 2>&1 | awk '/active|started/ {n++} END {print "   snmpd running on " n+0 " servers/containers (snmp-enable.sh)"}'
./publish.sh >/dev/null 2>&1 && echo "   publish/ refreshed (cluster CA, routes, DNS for the workstations)" || echo "   publish.sh skipped"
HN=$(hostname); open=0
EVID= K "kubectl -n webui get secret inference-key >/dev/null 2>&1 && kubectl -n ai-sim get endpoints llm >/dev/null 2>&1" >/dev/null \
  || { open=1; echo "   OPEN (operator):  $HN:<repo>/post-deploy.sh     -> the lab's own model + Open WebUI (needs no API key)"; }
[ $open = 0 ] && echo "   Open WebUI on the lab's own model: present"
[[ " $SERVICES " == *" harbor "* ]] && echo "   optional (operator): ssh -t $HN <repo>/harbor-password.sh   |   ssh $HN /root/ai-fabric/secrets-to-s3.sh"
# lab CA: the firewall UI certificate needs the firewall password (operator); a redeploy keeps it once fw-backup.sh has captured it
if python3 -c 'import gen,sys; sys.exit(0 if gen.LAB_CA else 1)'; then
  timeout 10 openssl s_client -connect "$(mgmt fw):443" </dev/null 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | grep -q "ai-fabric Platform CA" \
    && echo "   firewall UI: lab CA certificate in place" \
    || echo "   OPEN (operator, needs the firewall password):  ssh -t $HN <repo>/fw-ui-cert.sh   then   ssh -t $HN <repo>/fw-backup.sh"
fi

# a (re)start of 39 nodes leaves hundreds of Warning events (NodeNotReady, Rebooted, FailedMount, probes): history once all stages passed
[ $BAD = 0 ] && { ./clear-warnings.sh 60 | sed 's/^/   /'; [ "${PIPESTATUS[0]}" = 0 ] || fail "Warning events are coming back (see above)"; }

printf '\n== %s  finished in %d min: %s\n' "$(date +%T)" $(( ($(date +%s) - T0) / 60 )) "$([ $BAD = 0 ] && echo 'LAB FULLY WORKING' || echo "$BAD STAGE(S) FAILED")"
exit $BAD
