#!/bin/sh
# Usage: ./scripts/setup.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFS_DIR="$SCRIPT_DIR/../confs"

# p3 and the bonus share the cluster name, so start from a clean one
if k3d cluster list --no-headers 2>/dev/null | grep -q '^iot '; then
    echo "Cluster 'iot' already exists, deleting it first."
    k3d cluster delete iot
fi

# expose port 8888 from the host to the loadbalancer for the wil-playground app
k3d cluster create iot --port "8888:30888@loadbalancer"

# the subject asks for two namespaces: one for Argo CD, one named dev
for ns in argocd dev; do
    kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns"
done

kubectl apply -n argocd --server-side --force-conflicts \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# wait for Argo CD to be ready before applying the application config
kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s

kubectl apply -f "$CONFS_DIR/argocd-app.yaml"
