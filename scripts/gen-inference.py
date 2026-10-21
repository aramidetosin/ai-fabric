#!/usr/bin/env python3
"""Emit the Kubernetes manifests for the inference gateway of one lab.

Path shape:
  https://inference.platform.<domain>/models/<uuid>/proxy/v1/chat/completions

Layers:
  Cilium Gateway (edge TLS, *.platform wildcard cert)
    -> APISIX (standalone, data_plane, yaml config): route /models/<uuid>/proxy/*
       strips the prefix and forwards to
    -> LiteLLM (OpenAI-compatible), which proxies to OpenRouter.

Auth is a LiteLLM master key, presented as `Authorization: Bearer <key>`; APISIX
passes the header through and LiteLLM validates it. The master key and the
OpenRouter key are NOT emitted here: they live in secret inference/litellm-secret,
created by deploy-inference.sh. This file is safe to commit.

Usage:
  gen-inference.py <lab>          # print the YAML for that lab (apply with kubectl)
  gen-inference.py <lab> map      # print "model<TAB>uuid" lines (for endpoint listing)
"""
import os, sys, uuid

APISIX_IMAGE = "apache/apisix:3.9.1-debian"
LITELLM_IMAGE = "ghcr.io/berriai/litellm:main-stable"

# curated model set: friendly name -> OpenRouter model id (LiteLLM openrouter/ provider)
_DEFAULT_MODELS = [
    ("deepseek-ai/DeepSeek-V4-Pro-0813", "openrouter/deepseek/deepseek-v4-pro-0813"),
    ("qwen/qwen-2.5-72b-instruct",       "openrouter/qwen/qwen-2.5-72b-instruct"),
    ("openai/gpt-4o-mini",               "openrouter/openai/gpt-4o-mini"),
]
MODELS = _DEFAULT_MODELS

# stable per-model UUID (uuid5, same across labs so a model's id is platform-wide)
def model_uuid(name):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "https://ai-fabric.lab/models/" + name))


def litellm_config():
    lines = ["model_list:"]
    for name, orm in MODELS:
        lines += [
            f"  - model_name: {name}",
            "    litellm_params:",
            f"      model: {orm}",
            "      api_key: os.environ/OPENROUTER_API_KEY",
        ]
    lines += [
        "general_settings:",
        "  master_key: os.environ/LITELLM_MASTER_KEY",
        "litellm_settings:",
        "  drop_params: true",
        "  request_timeout: 120",
    ]
    return "\n".join(lines)


def apisix_standalone_config():
    return (
        "deployment:\n"
        "  role: data_plane\n"
        "  role_data_plane:\n"
        "    config_provider: yaml\n"
        "apisix:\n"
        "  enable_admin: false\n"
        "  node_listen: 9080\n"
        "nginx_config:\n"
        "  user: root\n"
        "  worker_processes: \"1\"\n"
    )


def apisix_routes():
    out = ["upstreams:",
           "  - id: litellm",
           "    type: roundrobin",
           "    nodes:",
           '      "litellm.inference.svc.cluster.local:4000": 1',
           "    timeout:",
           "      connect: 60",
           "      send: 600",
           "      read: 600",
           "routes:"]
    for i, (name, _orm) in enumerate(MODELS, 1):
        u = model_uuid(name)
        out += [
            f"  - id: \"{i}\"",
            f"    name: {name}",
            f"    uri: /models/{u}/proxy/*",
            "    methods: [GET, POST]",
            "    plugins:",
            "      proxy-rewrite:",
            f"        regex_uri: [\"^/models/{u}/proxy/(.*)\", \"/$1\"]",
            "    upstream_id: litellm",
    ]
    out.append("#END")
    return "\n".join(out)


def indent(block, n):
    pad = " " * n
    return "\n".join(pad + l if l else l for l in block.split("\n"))


def manifests(lab):
    domain = os.environ.get("LAB_DOMAIN") or "lab.ai"
    host = f"inference.platform.{domain}"
    return f"""\
apiVersion: v1
kind: Namespace
metadata:
  name: inference
  labels:
    app.kubernetes.io/part-of: inference-gateway
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: litellm-config
  namespace: inference
data:
  config.yaml: |
{indent(litellm_config(), 4)}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: litellm
  namespace: inference
spec:
  replicas: 1
  selector:
    matchLabels: {{app: litellm}}
  template:
    metadata:
      labels: {{app: litellm}}
    spec:
      containers:
        - name: litellm
          image: {LITELLM_IMAGE}
          args: ["--config", "/etc/litellm/config.yaml", "--host", "0.0.0.0", "--port", "4000"]
          ports: [{{containerPort: 4000}}]
          env:
            - name: OPENROUTER_API_KEY
              valueFrom: {{secretKeyRef: {{name: litellm-secret, key: openrouter-key}}}}
            - name: LITELLM_MASTER_KEY
              valueFrom: {{secretKeyRef: {{name: litellm-secret, key: master-key}}}}
          resources:
            requests: {{cpu: "100m", memory: "384Mi"}}
            limits: {{memory: "1Gi"}}
          readinessProbe:
            httpGet: {{path: /health/liveliness, port: 4000}}
            initialDelaySeconds: 20
            periodSeconds: 10
            failureThreshold: 30
          volumeMounts:
            - {{name: config, mountPath: /etc/litellm}}
      volumes:
        - name: config
          configMap: {{name: litellm-config}}
---
apiVersion: v1
kind: Service
metadata:
  name: litellm
  namespace: inference
spec:
  selector: {{app: litellm}}
  ports: [{{port: 4000, targetPort: 4000}}]
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: apisix-config
  namespace: inference
data:
  config.yaml: |
{indent(apisix_standalone_config(), 4)}
  apisix.yaml: |
{indent(apisix_routes(), 4)}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: apisix
  namespace: inference
spec:
  replicas: 1
  selector:
    matchLabels: {{app: apisix}}
  template:
    metadata:
      labels: {{app: apisix}}
    spec:
      containers:
        - name: apisix
          image: {APISIX_IMAGE}
          securityContext: {{runAsUser: 0, runAsGroup: 0}}
          ports: [{{containerPort: 9080}}]
          resources:
            requests: {{cpu: "100m", memory: "256Mi"}}
            limits: {{memory: "1Gi"}}
          readinessProbe:
            tcpSocket: {{port: 9080}}
            initialDelaySeconds: 10
            periodSeconds: 10
          volumeMounts:
            - {{name: config, mountPath: /usr/local/apisix/conf/config.yaml, subPath: config.yaml}}
            - {{name: config, mountPath: /usr/local/apisix/conf/apisix.yaml, subPath: apisix.yaml}}
      volumes:
        - name: config
          configMap: {{name: apisix-config}}
---
apiVersion: v1
kind: Service
metadata:
  name: apisix-gateway
  namespace: inference
spec:
  selector: {{app: apisix}}
  ports: [{{port: 80, targetPort: 9080}}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: inference
  namespace: inference
spec:
  parentRefs:
    - {{name: gateway, namespace: gateway, sectionName: https}}
  hostnames: ["{host}"]
  rules:
    - matches:
        - path: {{type: PathPrefix, value: /models/}}
      backendRefs:
        - {{name: apisix-gateway, port: 80}}
"""


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: gen-inference.py <lab> [map]")
    lab = sys.argv[1]
    global MODELS
    if len(sys.argv) > 2 and sys.argv[2] == "map":
        for name, _ in MODELS:
            print(f"{name}\t{model_uuid(name)}")
        return
    sys.stdout.write(manifests(lab))


if __name__ == "__main__":
    main()
