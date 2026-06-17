#!/usr/bin/env bash
set -e

ARGOCD_VERSION="v3.4.3"
ARGOCD_NAMESPACE="argocd"
ARGOCD_MANIFEST_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
ARGOCD_MANIFEST_FILE="/tmp/argocd-install.yaml"
export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

echo "📥 [PHASE 2.1] Pre-fetching Argo CD manifests..."
curl -sSLf --max-time 30 --connect-timeout 10 -o "${ARGOCD_MANIFEST_FILE}" "${ARGOCD_MANIFEST_URL}"

echo "🛡️ [PHASE 2.2] Deploying Argo CD..."
kubectl create namespace ${ARGOCD_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n ${ARGOCD_NAMESPACE} --server-side --force-conflicts -f "${ARGOCD_MANIFEST_FILE}"

echo "⏳ Waiting for Argo CD pods to initialize..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n ${ARGOCD_NAMESPACE} --timeout=300s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-application-controller -n ${ARGOCD_NAMESPACE} --timeout=300s

echo "🔒 [PHASE 2.3] Applying eBPF Least Privilege Network Policies..."
cat << 'EOF' | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: argocd-egress-external
  namespace: argocd
spec:
  description: "Allow Argo CD to fetch manifests from external Git providers"
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: argocd-application-controller
  egress:
  - toEntities:
    - world
    toPorts:
    - ports:
      - port: "443"
        protocol: TCP
  - toEndpoints:
    - matchLabels:
        "k8s:io.kubernetes.pod.namespace": kube-system
    toPorts:
    - ports:
      - port: "53"
        protocol: UDP
      - port: "53"
        protocol: TCP
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: argocd-internal-communication
  namespace: argocd
spec:
  description: "Allow Argo CD component pod-to-pod communication"
  endpointSelector:
    matchLabels:
      app.kubernetes.io/part-of: argocd
  ingress:
  - fromEndpoints:
    - matchLabels:
        app.kubernetes.io/part-of: argocd
  egress:
  - toEndpoints:
    - matchLabels:
        app.kubernetes.io/part-of: argocd
  - toEndpoints:
    - matchLabels:
        "k8s:io.kubernetes.pod.namespace": kube-system
    toPorts:
    - ports:
      - port: "53"
        protocol: UDP
      - port: "53"
        protocol: TCP
  - toEntities:
    - world
    toPorts:
    - ports:
      - port: "443"
        protocol: TCP
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: deny-default-argocd
  namespace: argocd
spec:
  description: "Default deny-all ingress (explicit allowlist required)"
  endpointSelector: {}
  ingress:
  - fromEndpoints:
    - matchLabels:
        "k8s:io.kubernetes.pod.namespace": argocd
EOF

echo "✅ Extracting initial Argo CD Admin Password:"
kubectl -n ${ARGOCD_NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
