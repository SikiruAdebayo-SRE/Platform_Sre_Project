# File: bootstrap.sh
#!/usr/bin/env bash
set -e

echo "🚀 [STAGE 1] Bootstrapping Sovereign K3s Control Plane..."
# Install K3s securely without deploying external cloud-controller-managers
curl -sfL https://get.k3s.io | sh -

# Export kubeconfig for local terminal execution
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >> ~/.bashrc

# Wait for the Kubernetes API to lock and listen
echo "⏳ Waiting for Kubernetes API..."
sleep 15 

echo "🛡️ [STAGE 2] Enforcing Argo CD Security Boundaries..."
# Create isolated namespace for the GitOps controller
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# SRE FIX: Deploy Argo CD utilizing Server-Side Apply to bypass the 262KB CRD annotation limit
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "⏳ Waiting for Argo CD pods to initialize (This takes ~60 seconds)..."
kubectl wait --for=condition=ready pod --all -n argocd --timeout=300s

echo "🔗 [STAGE 3] Applying the Root GitOps Configuration..."
# Apply the "App of Apps" launcher to hand over control to GitHub
kubectl apply -f argocd/bootstrap-root-app.yaml -n argocd

echo "✅ Bootstrap Complete! Extracting initial Argo CD Admin Password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
