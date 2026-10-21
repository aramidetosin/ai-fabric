#!/usr/bin/env bash
# Hide OpenRouter's batch-only model variants (ids ending in ":batch") in Open WebUI.
# They appear in the model picker next to the chat models but every request to them
# is refused ("only available through the Batch API"). Hidden models are Open WebUI
# model entries with is_active=false; the picker and /api/models skip them.
# Usage: scripts/webui-hide-batch.sh [lab]   (default: ai-fabric)
# Runs anywhere that resolves webui.platform.<domain> (a PC, the bastion, a
# workstation with the hosts entries); CURL_OPTS=-sk when the cluster CA is not installed.
set -u
bastion_of() { docker ps --format "{{.Names}}" | grep -E "^clab-(.+-)?$1-.*bastion" | head -1; }
CURL_OPTS=${CURL_OPTS:--sk}
LABS=${*:-"ai-fabric"}
for L in $LABS; do
  H="webui.platform.${LAB_DOMAIN:-${DOMAIN:-lab.ai}}"
  T=$(curl $CURL_OPTS --max-time 20 -H 'Content-Type: application/json' "https://$H/api/v1/auths/signin" -d '{"email":"","password":""}' | jq -r '.token // empty')
  if [ -z "$T" ]; then echo "$L: no admin token from https://$H (single-user sign-in)"; continue; fi
  M=$(curl $CURL_OPTS --max-time 90 -H "Authorization: Bearer $T" "https://$H/api/models" | jq -r '.data[] | select(.id | endswith(":batch")) | [.id, .name] | @tsv')
  B=$(printf '%s\n' "$M" | grep -c .)
  hidden=0
  while IFS=$'\t' read -r id name; do
    [ -z "$id" ] && continue
    r=$(curl $CURL_OPTS --max-time 20 -H "Authorization: Bearer $T" -H 'Content-Type: application/json' "https://$H/api/v1/models/create" \
      -d "$(jq -cn --arg id "$id" --arg name "$name" '{id:$id, base_model_id:null, name:$name, meta:{}, params:{}, access_control:null, is_active:false}')")
    echo "$r" | jq -e '.id' >/dev/null 2>&1 && hidden=$((hidden+1))
  done <<< "$M"
  left=$(curl $CURL_OPTS --max-time 90 -H "Authorization: Bearer $T" "https://$H/api/models" | jq '[.data[] | select(.id | endswith(":batch"))] | length')
  total=$(curl $CURL_OPTS --max-time 90 -H "Authorization: Bearer $T" "https://$H/api/models" | jq '.data | length')
  echo "$L: $B batch variants listed, $hidden hidden now, $left still listed, $total models offered"
done
