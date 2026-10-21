#!/bin/bash
# OPERATOR STEP -- set YOUR password for the Harbor `admin` user. Needs a terminal (the prompt is hidden):
#   ssh -t <host> <repo>/harbor-password.sh
# The bootstrap password lives in Secret harbor/harbor-admin (random, generated in the cluster, never shown by the lab scripts). This script
# changes it through the Harbor API and stores the new one in the same Secret, so the lab's jobs keep working. Nothing is written to disk.
set -uo pipefail
if [ ! -t 0 ] || [ ! -t 1 ]; then echo "needs a terminal so the prompt stays hidden. Run:  ssh -t $(hostname) <repo>/harbor-password.sh" >&2; exit 2; fi
B=$(docker ps --format '{{.Names}}' | grep -E '^clab-ai-fabric-.*bastion' | head -1); [ -n "$B" ] || { echo "no ai-fabric bastion running" >&2; exit 1; }
echo "Harbor password rules: 8-128 characters with at least one upper-case letter, one lower-case letter and one digit."
read -r -s -p "New Harbor admin password: " N1; echo; read -r -s -p "Again: " N2; echo
[ -n "$N1" ] && [ "$N1" = "$N2" ] || { echo "empty or not identical: nothing changed" >&2; exit 1; }
printf '%s' "$N1" | docker exec -i "$B" bash -lc '
  NEW=$(cat); OLD=$(kubectl -n harbor get secret harbor-admin -o jsonpath={.data.HARBOR_ADMIN_PASSWORD} | base64 -d)
  BODY=$(jq -n --arg o "$OLD" --arg n "$NEW" "{old_password: \$o, new_password: \$n}")
  c=$(curl -sS --cacert /shared/ai-fabric/cluster-ca.crt -o /tmp/hp.out -w "%{http_code}" -u "admin:$OLD" -H "Content-Type: application/json" -X PUT https://harbor.platform.lab.ai/api/v2.0/users/1/password -d "$BODY")
  if [ "$c" = 200 ]; then kubectl -n harbor create secret generic harbor-admin --from-literal=HARBOR_ADMIN_PASSWORD="$NEW" --dry-run=client -o yaml | kubectl apply -f - >/dev/null && echo "password changed; Secret harbor/harbor-admin updated"
  else echo "Harbor answered HTTP $c: $(cut -c1-200 /tmp/hp.out)"; fi; rm -f /tmp/hp.out'
unset N1 N2
