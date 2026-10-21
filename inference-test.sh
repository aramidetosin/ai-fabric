#!/bin/sh
# inference-test.sh: call every model on the ai-fabric inference gateway once and report what came back.
# POSIX sh on purpose: the same file runs on the Alpine lab clients (pc-1, pc-2), on macOS and on Ubuntu.
#
#   ./inference-test.sh              test every model
#   ./inference-test.sh --save-key   store the bearer key locally (prompts, never echoes, chmod 600)
#   ./inference-test.sh -m gpt       test only the models whose name matches "gpt"
#
# The bearer key is NEVER stored in this file. It is read from $LITELLM_KEY, or from ~/.ai-fabric/inference-key.
# Get it with:  ssh -t <host> <repo>/show-creds.sh    then run  ./inference-test.sh --save-key
#
# The model UUIDs below are the gateway's route ids, from `gen-inference.py ai-fabric map` on the lab host.
# They are not secret. Refresh them after a redeploy with:
#   ssh site-a python3 /root/ai-fabric/scripts/gen-inference.py ai-fabric map
set -u
HOST=${AI_FABRIC_INFER_HOST:-inference.platform.lab.ai}
KEYFILE=${AI_FABRIC_KEYFILE:-$HOME/.ai-fabric/inference-key}
PROMPT=${AI_FABRIC_PROMPT:-"Reply with exactly: OK"}
MODELS="deepseek-ai/DeepSeek-V4-Pro-0813=565df347-26cb-598a-b838-b7e9531f00fa
qwen/qwen-2.5-72b-instruct=5bfb8175-7fd3-54d7-b4a3-128daf1b7479
openai/gpt-4o-mini=3fda6363-9031-5ce4-919c-232ebeede362
Qwen/Qwen2.5-0.5B-Instruct=1f6e4487-6ee5-56a7-bf59-bcc2d839c8f3"

FILTER=""
while [ $# -gt 0 ]; do case "$1" in
  --save-key)
    [ -t 0 ] || { echo "refusing: --save-key needs a terminal (use ssh -t), so the key is never read from a pipe or a log" >&2; exit 1; }
    mkdir -p "$(dirname "$KEYFILE")"; chmod 700 "$(dirname "$KEYFILE")" 2>/dev/null
    printf 'inference bearer key (sk-aif-...): '; stty -echo 2>/dev/null; read -r K; stty echo 2>/dev/null; echo
    [ -n "$K" ] || { echo "nothing entered, key file unchanged" >&2; exit 1; }
    umask 077; printf '%s' "$K" > "$KEYFILE"; chmod 600 "$KEYFILE"; unset K
    echo "saved to $KEYFILE (mode 600)"; exit 0;;
  -m) FILTER=$2; shift;;
  -h|--help) sed -n '2,16p' "$0"; exit 0;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2;;
esac; shift; done

KEY=${LITELLM_KEY:-}
[ -n "$KEY" ] || { [ -r "$KEYFILE" ] && KEY=$(cat "$KEYFILE"); }
[ -n "$KEY" ] || { echo "no bearer key: set \$LITELLM_KEY or run  $0 --save-key   (get it from: ssh -t <host> <repo>/show-creds.sh)" >&2; exit 1; }

# Apple's curl, not Homebrew's, when both exist: only /usr/bin/curl trusts the macOS System keychain, so a Homebrew curl first
# on PATH fails the lab CA with "unable to get local issuer certificate". On Linux and Alpine this is just the normal curl.
CURL=curl; [ -x /usr/bin/curl ] && CURL=/usr/bin/curl

# which address are we actually talking to, and over which path -- worth seeing when a machine has the wrong hosts entry
ADDR=$(getent ahostsv4 "$HOST" 2>/dev/null | awk '{print $1; exit}')
[ -n "$ADDR" ] || ADDR=$(dscacheutil -q host -a name "$HOST" 2>/dev/null | awk '/^ip_address/ {print $2; exit}')
printf '%s -> %s   (host %s)\n\n' "$HOST" "${ADDR:-UNRESOLVED}" "$(hostname)"
printf '%-34s %-8s %-8s %s\n' MODEL HTTP TIME REPLY

rc=0
echo "$MODELS" | while IFS='=' read -r model uuid; do
  [ -n "$model" ] || continue
  case "$model" in *"$FILTER"*) ;; *) continue;; esac
  URL="https://$HOST/models/$uuid/proxy/v1/chat/completions"
  BODY=$(printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":24}' "$model" "$PROMPT")
  OUT=$("$CURL" -sS --max-time 90 -w '\n%{http_code} %{time_total}' \
        -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
        -d "$BODY" "$URL" 2>&1)
  STAT=$(printf '%s' "$OUT" | tail -1); CODE=${STAT%% *}; T=${STAT##* }
  # pull "content":"..." out of the JSON without needing jq
  REPLY=$(printf '%s' "$OUT" | sed -n 's/.*"content"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$REPLY" ] || REPLY=$(printf '%s' "$OUT" | sed '$d' | tr -d '\n' | cut -c1-70)
  # LiteLLM runs without a database here, so ANY key that is not the master key fails its lookup with "No connected db" rather
  # than "invalid key". That reads like a broken backend but almost always means the wrong credential was saved -- the inference
  # bearer key is the sk-aif-... one, not the (much longer) OpenRouter key that sits next to it in show-creds.sh.
  case "$OUT" in *no_db_connection*|*"No connected db"*)
    REPLY="wrong key? this is the sk-aif-... INFERENCE key, not the OpenRouter one -- re-run with --save-key";; esac
  case "$CODE" in 200) ;; *) rc=1;; esac
  printf '%-34s %-8s %-8s %s\n' "$model" "$CODE" "${T}s" "$REPLY"
done
exit $rc
