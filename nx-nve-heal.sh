#!/bin/bash
# nx-nve-heal.sh: find and heal a Nexus 9300v vPC leaf that does not decapsulate VXLAN. Called by finish.sh's settle stage when a sweep round loses pings
# (Nexus profiles only), so a boot needs no hand step for it.
# Seen on site-a 2026-10-04: after the TCAM-carve reloads (its twin fe-gpu-leaf2 had needed the second reload for stuck loopbacks) fe-gpu-leaf1 had a
# perfect control plane (vPC adjacency and all 16 vPCs up, 10 NVE peers, OSPF, EVPN, loopback1 with the pair's VIP: all as its twin) but its nve1 had
# received 72 unicast packets against 89,506 sent: every packet the spines handed to it for the pair's servers was dropped. The spines balance ICMP per
# packet, so about half of the pings to the 16 servers of the pair were lost, from every other node, at random. A capture on gpu1 showed every request
# that arrived came through leaf2. "shutdown / no shutdown" on nve1 reprogrammed it: input counter 72 -> 67,984 in a minute, 0 % loss.
# Signature, per vPC pair, meaningful only while the servers exchange traffic: in 10 s the input unicast counter of nve1 moves on one leaf (>= MIN packets)
# and not on its twin (<= 2), twice in a row. Exit 0 = nothing wrong or healed, 1 = a leaf still does not decapsulate after the bounce.
cd "$(dirname "$0")"; . ./lib.sh; unset EVID
python3 -c 'import gen, sys; sys.exit(0 if gen.NXOS else 1)' 2>/dev/null || exit 0
MIN=${NVE_HEAL_MIN:-200}
rx() { timeout 60 ssh -n $SSHO "ops@$(mgmt "$1")" "show interface nve1 | include ucast" 2>/dev/null | head -1 | grep -oE 'ucast: [0-9]+' | grep -oE '[0-9]+'; }
delta() { local a b; a=$(rx "$1"); sleep 10; b=$(rx "$1"); [ -n "$a" ] && [ -n "$b" ] && echo $((b - a)) || echo -1; }
deaf() { local l=$1 t=$2 dl dt T; T=$(mktemp -d)      # is leaf l deaf while its twin t hears? both sampled over the same 10 s
  delta "$l" > "$T/l" & delta "$t" > "$T/t" & wait; dl=$(cat "$T/l"); dt=$(cat "$T/t"); find "${T:?}" -delete
  echo "$dl $dt"; [ "$dl" -ge 0 ] && [ "$dl" -le 2 ] && [ "$dt" -ge "$MIN" ]; }
rc=0
while read -r a b; do [ -n "$b" ] || continue
  for pair in "$a $b" "$b $a"; do read -r l t <<< "$pair"
    d=$(deaf "$l" "$t") || continue; d2=$(deaf "$l" "$t") || continue
    echo "$l does not decapsulate (nve1 input unicast +${d%% *} / +${d2%% *} packets in 10 s, its twin $t +${d##* } / +${d2##* }) -> shutdown / no shutdown on nve1"
    timeout 90 ssh -n $SSHO "ops@$(mgmt "$l")" "configure terminal ; interface nve1 ; shutdown ; no shutdown ; end" >/dev/null 2>&1; sleep 45
    d=$(deaf "$l" "$t") && { echo "$l STILL does not decapsulate after the bounce (+${d%% *} against +${d##* } on $t): reload it (nx-tcam-reload.sh $l)"; rc=1; } || echo "$l HEALED: nve1 input unicast +${d%% *} packets in 10 s ($t +${d##* })"
  done
done < <(python3 -c 'import gen; [print(*v) for v in gen.PAIR.values() if len(v) == 2]')
exit $rc
