#!/usr/bin/env bash
set -e

K3S_CLUSTER_CIDR="10.244.0.0/16"
CILIUM_MTU="1400"
export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

echo "🛡️ [PHASE 1.1] Validating Hypervisor DNS..."
HYPERVISOR_RESOLVERS=$(grep "nameserver" /etc/resolv.conf | awk '{print $2}' | tr '\n' ' ')
if ! nslookup github.com >/dev/null 2>&1; then
  echo "❌ Cannot resolve external domains. Aborting."
  exit 1
fi

echo "🚀 [PHASE 1.2] Bootstrapping K3s Control Plane (Flannel & Traefik Disabled)..."
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--flannel-backend=none --disable-network-policy --disable traefik --cluster-cidr=${K3S_CLUSTER_CIDR}" sh -
echo "export KUBECONFIG=${KUBECONFIG}" >> ~/.bashrc
sleep 15 

echo "🕸️ [PHASE 1.3] Injecting Cilium eBPF Mesh..."
cd /tmp
curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz
tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
rm cilium-linux-amd64.tar.gz

cilium install \
  --set l7Policy.enabled=true \
  --set policyAuditMode=false \
  --set policyEnforcementMode=default
cilium status --wait

echo "🔧 [PHASE 1.4] Enforcing MTU 1400 and DNS Stability..."
kubectl patch configmap cilium-config -n kube-system --type merge -p '{"data":{"mtu":"'"${CILIUM_MTU}"'"}}'
kubectl rollout restart ds cilium -n kube-system
kubectl rollout status ds cilium -n kube-system --timeout=120s

UPSTREAM_RESOLVERS=""
for resolver in $HYPERVISOR_RESOLVERS; do
  UPSTREAM_RESOLVERS="${UPSTREAM_RESOLVERS}        forward . ${resolver}\n"
done

cat << EOF | kubectl apply -n kube-system -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
        }
        prometheus :9153
$(echo -e "$UPSTREAM_RESOLVERS")
        cache 30
        reload
    }
EOF

kubectl rollout restart deployment coredns -n kube-system
kubectl rollout status deployment coredns -n kube-system --timeout=90s

echo "✅ Foundation Stable. You may now execute the GitOps script."
