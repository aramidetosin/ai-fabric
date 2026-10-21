#!/bin/bash
# harbor-deploy.sh: Harbor + an S3 stand-in + Longhorn backups for ai-fabric (idempotent; re-run after a redeploy once Kubernetes is complete).
#   1. MinIO on the storage node      = the FlashBlade's S3 service in this lab (buckets: harbor, longhorn-backups)
#   2. Longhorn backup target         = s3://longhorn-backups@us-east-1/ on that S3 (volume backups / DR; RWX volumes need nothing extra)
#   3. Harbor 2.15 (chart 1.19.2)      = https://harbor.platform.lab.ai through the lab Gateway, blobs in S3, state on Longhorn, on ctrl4-6
#   4. proxy-cache projects           = proxy-dockerhub, proxy-quay, proxy-ghcr, proxy-k8s
#   5. every node's containerd        = trusts the cluster CA for Harbor and pulls through the proxy caches first (harbor-trust.sh)
# CREDENTIALS: every secret is generated INSIDE the cluster (openssl rand in the bastion -> kubectl create secret) and is never printed,
# logged or written to disk here. The Harbor admin gets a random bootstrap password in Secret harbor/harbor-admin; the OPERATOR sets his own
# with  ssh -t <host> <repo>/harbor-password.sh  (or reads the bootstrap one himself, see README).
set -uo pipefail
cd "$(dirname "$0")"; . ./lib.sh
export KT=2400      # K() cuts a command off after 180 s by default: a first Harbor rollout (helm --wait) takes far longer
CHART=1.19.2; S3EP=http://minio.s3.svc.cluster.local:9000
step() { printf '\n== %s\n' "$*"; }
step "1/5 S3 stand-in (MinIO on the storage node)"
K "for n in s3 harbor; do kubectl create ns \$n --dry-run=client -o yaml | kubectl apply -f - >/dev/null; done
   kubectl -n s3 get secret minio-root >/dev/null 2>&1 || kubectl -n s3 create secret generic minio-root --from-literal=rootUser=ai-fabric-s3 --from-literal=rootPassword=\"\$(openssl rand -hex 20)\" >/dev/null
   U=\$(kubectl -n s3 get secret minio-root -o jsonpath={.data.rootUser} | base64 -d); P=\$(kubectl -n s3 get secret minio-root -o jsonpath={.data.rootPassword} | base64 -d)
   kubectl -n harbor create secret generic harbor-s3 --from-literal=REGISTRY_STORAGE_S3_ACCESSKEY=\"\$U\" --from-literal=REGISTRY_STORAGE_S3_SECRETKEY=\"\$P\" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
   kubectl -n longhorn-system create secret generic minio-longhorn --from-literal=AWS_ACCESS_KEY_ID=\"\$U\" --from-literal=AWS_SECRET_ACCESS_KEY=\"\$P\" --from-literal=AWS_ENDPOINTS=$S3EP --dry-run=client -o yaml | kubectl apply -f - >/dev/null
   kubectl -n harbor get secret harbor-admin >/dev/null 2>&1 || kubectl -n harbor create secret generic harbor-admin --from-literal=HARBOR_ADMIN_PASSWORD=\"Hb1-\$(openssl rand -hex 12)\" >/dev/null
   echo secrets: \$(kubectl -n s3 get secret minio-root -o name) \$(kubectl -n harbor get secret harbor-s3 harbor-admin -o name | tr '\n' ' ') \$(kubectl -n longhorn-system get secret minio-longhorn -o name)"
for f in minio.yaml harbor-values.yaml harbor-projects-job.yaml; do docker cp "harbor/$f" "$LAB-bastion:/tmp/$f" >/dev/null; done
K "kubectl -n s3 delete job minio-buckets --ignore-not-found >/dev/null; kubectl apply -f /tmp/minio.yaml >/dev/null && kubectl -n s3 rollout status deploy/minio --timeout=600s | tail -1 && kubectl -n s3 wait --for=condition=complete job/minio-buckets --timeout=600s >/dev/null && kubectl -n s3 logs job/minio-buckets | tail -3"
step "2/5 Longhorn backup target on that S3"
K "kubectl -n longhorn-system patch backuptargets.longhorn.io default --type merge -p '{\"spec\":{\"backupTargetURL\":\"s3://longhorn-backups@us-east-1/\",\"credentialSecret\":\"minio-longhorn\",\"pollInterval\":\"5m0s\"}}' >/dev/null
   for i in \$(seq 1 30); do a=\$(kubectl -n longhorn-system get backuptargets.longhorn.io default -o jsonpath={.status.available}); [ \"\$a\" = true ] && break; sleep 10; done
   kubectl -n longhorn-system get backuptargets.longhorn.io default -o custom-columns=URL:.spec.backupTargetURL,SECRET:.spec.credentialSecret,AVAILABLE:.status.available"
step "3/5 Harbor (helm chart harbor/harbor $CHART)"
K "helm repo add harbor https://helm.goharbor.io >/dev/null 2>&1; helm repo update harbor >/dev/null 2>&1
   helm upgrade --install harbor harbor/harbor --version $CHART -n harbor -f /tmp/harbor-values.yaml --wait --timeout 25m 2>&1 | tail -4
   kubectl -n harbor get deploy,sts --no-headers | awk '{print \$1, \$2}'; kubectl -n harbor get httproute --no-headers"
step "4/5 proxy-cache projects"
K "kubectl -n harbor delete job harbor-proxy-projects --ignore-not-found >/dev/null; kubectl apply -f /tmp/harbor-projects-job.yaml >/dev/null; kubectl -n harbor wait --for=condition=complete job/harbor-proxy-projects --timeout=900s >/dev/null; kubectl -n harbor logs job/harbor-proxy-projects | grep -v waiting"
step "5/5 containerd on every node: trust Harbor, pull through its proxy caches first"
./harbor-trust.sh
echo; echo "Harbor: https://harbor.platform.lab.ai   (user admin; set your password:  ssh -t $(hostname) <repo>/harbor-password.sh)"
