#!/usr/bin/env bash
set -e

echo "🚀 [STAGE 1] Bootstrapping Sovereign K3s Control Plane (Flannel Disabled)..."
# SRE FIX: Enforce unique PodCIDR and explicitly disable Flannel and Network Policies to allow Cilium eBPF takeover
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--flannel-backend=none --disable-network-policy --cluster-cidr=10.244.0.0/16" sh -

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >> ~/.bashrc

echo "⏳ Waiting for Kubernetes API to lock and listen..."
sleep 15 

echo "🕸️ [STAGE 2] Injecting Cilium eBPF Container Network Interface..."
# Install the Cilium CLI locally
curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz
tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
rm cilium-linux-amd64.tar.gz

# Bootstrap the eBPF datapath natively into the cluster
cilium install

echo "⏳ Waiting for Cilium eBPF agents to establish the kernel mesh..."
cilium status --wait

echo "🛡️ [STAGE 3] Enforcing Argo CD Security Boundaries..."
# Create isolated namespace for the GitOps controller
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# SRE FIX: Deploy Argo CD utilizing Server-Side Apply to bypass the 262KB CRD annotation limit
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "⏳ Waiting for Argo CD pods to initialize over the eBPF network (This takes ~60 seconds)..."
kubectl wait --for=condition=ready pod --all -n argocd --timeout=300s

echo "🔗 [STAGE 4] Applying the Root GitOps Configuration..."
# Apply the "App of Apps" launcher to hand over control to GitHub
kubectl apply -f argocd/bootstrap-root-app.yaml -n argocd

echo "✅ Bootstrap Complete! Extracting initial Argo CD Admin Password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
