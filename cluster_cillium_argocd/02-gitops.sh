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

echo "⚙️ [PHASE 2.3] Patching Argo CD for Gateway API HTTP Routing..."
kubectl patch configmap argocd-cmd-params-cm -n ${ARGOCD_NAMESPACE} --type merge -p '{"data":{"server.insecure":"true"}}'
kubectl patch deployment argocd-server -n ${ARGOCD_NAMESPACE} --type=json -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--insecure"}]'

echo "⏳ Waiting for Argo CD pods to initialize..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n ${ARGOCD_NAMESPACE} --timeout=300s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-application-controller -n ${ARGOCD_NAMESPACE} --timeout=300s

echo "🔒 [PHASE 2.4] Applying eBPF Least Privilege Network Policies..."
cat << 'EOF' | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: argocd-internal-communication
  namespace: argocd
spec:
  description: "Allow Argo CD pod-to-pod, API Server, and DNS communication"
  endpointSelector: {}
  ingress:
  - fromEndpoints:
    - matchLabels:
        "k8s:io.kubernetes.pod.namespace": "argocd"
  egress:
  # 1. Unblocks Redis & Dex (Allows intra-namespace routing)
  - toEndpoints:
    - matchLabels:
        "k8s:io.kubernetes.pod.namespace": "argocd"
        
  # 2. Unblocks the Kubernetes API Server (Fixes the 10.43.0.1 timeout)
  - toEntities:
    - kube-apiserver
    - host
    toPorts:
    - ports:
      - port: "443"
        protocol: TCP
        
  # 3. Allows DNS Resolution (CoreDNS)
  - toEndpoints:
    - matchLabels:
        "k8s:io.kubernetes.pod.namespace": "kube-system"
        "k8s:k8s-app": "kube-dns"
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
  name: argocd-egress-external
  namespace: argocd
spec:
  description: "Allow Argo CD Controllers to fetch manifests from GitHub"
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: argocd-repo-server
  egress:
  # ARCHITECTURAL FIX: 'world' entity required for internet egress in eBPF
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
  description: "Default deny-all with Kubelet health probe exception"
  endpointSelector: {}
  ingress:
  - fromEndpoints:
    - matchLabels:
        "k8s:io.kubernetes.pod.namespace": "argocd"
  # SRE FIX: Allow Kubelet Liveness/Readiness Probes through the eBPF mesh
  - fromEntities:
    - host
    - remote-node
EOF

echo "🌐 [PHASE 2.5] Provisioning Cilium Gateway API & HTTPRoute..."
cat << 'EOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: cilium
spec:
  controllerName: io.cilium/gateway-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main-gateway
  namespace: kube-system
spec:
  gatewayClassName: cilium
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-server-route
  namespace: argocd
spec:
  parentRefs:
  - name: main-gateway
    namespace: kube-system
  hostnames:
  - "argocd-iximiuz.sikiru.co.uk"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: argocd-server
      port: 80
EOF

echo "✅ Extracting initial Argo CD Admin Password:"
kubectl -n ${ARGOCD_NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
