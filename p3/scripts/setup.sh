#!/bin/sh
# Usage: ./setup.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFS_DIR="$SCRIPT_DIR/../confs"

set -e

# Create K3d cluster and expose port 8888 from host to loadbalancer for wil-playground app
k3d cluster create iot --port "8888:30888@loadbalancer"

# Create namespace
kubectl create namespace argocd
kubectl create namespace dev

# Install argocd
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for Argo CD to be ready before applying the application config
kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s
kubectl apply -f "$CONFS_DIR/argocd-app.yaml"
