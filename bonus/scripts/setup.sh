#!/bin/sh
# Usage: ./setup.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFS_DIR="$SCRIPT_DIR/../confs"

# Create K3d cluster and expose port 8888 from host to loadbalancer for wil-playground app
k3d cluster create iot --port "8888:30888@loadbalancer"

# Add the Helm chart repository
helm repo add gitlab https://charts.gitlab.io/
helm repo update
helm search repo gitlab

# Create namespace
kubectl create namespace argocd
kubectl create namespace dev
kubectl create namespace gitlab

# Install argocd
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for Argo CD to be ready before applying the application config
kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s
kubectl apply -f "$CONFS_DIR/argocd-app.yaml"

# Install GitLab using Helm
helm install gitlab gitlab/gitlab --namespace gitlab --create-namespace
