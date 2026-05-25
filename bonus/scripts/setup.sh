#!/bin/sh
# Usage: ./setup.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFS_DIR="$SCRIPT_DIR/../confs"

# Create K3d cluster
k3d cluster create iot --port "8888:30888@loadbalancer" --port "8443:30443@loadbalancer" --servers-memory 16g

# Add the Helm chart repository
helm repo add gitlab https://charts.gitlab.io/
helm repo update

# Create namespace
kubectl create namespace argocd
kubectl create namespace dev
kubectl create namespace gitlab

# Install argocd
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for Argo CD to be ready before applying the application config
kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s

# Install PostgreSQL for GitLab
helm install postgresql oci://registry-1.docker.io/bitnamicharts/postgresql \
  --namespace gitlab \
  --set auth.username=gitlab \
  --set auth.password=gitlab-password \
  --set auth.database=gitlabhq_production \
  --set primary.persistence.size=2Gi \
  --set primary.resources.requests.memory=512Mi \
  --set primary.resources.limits.memory=1Gi \
  --set primary.livenessProbe.initialDelaySeconds=120 \
  --set primary.readinessProbe.initialDelaySeconds=120
kubectl wait --for=condition=Ready pod/postgresql-0 -n gitlab --timeout=300s

# Install Redis for GitLab
helm install redis oci://registry-1.docker.io/bitnamicharts/redis \
  --namespace gitlab \
  --set auth.password=redis-password \
  --set master.persistence.size=2Gi \
  --set replica.replicaCount=0
kubectl wait --for=condition=Ready pod/redis-master-0 -n gitlab --timeout=300s

# Deploy MinIO manually (bitnami image removed from Docker Hub)
kubectl apply -f "$CONFS_DIR/minio.yaml"
kubectl wait --for=condition=Ready pod -l app=minio -n gitlab --timeout=300s

# Create required buckets in MinIO
kubectl run minio-setup --rm -i --restart=Never \
  --namespace gitlab \
  --image quay.io/minio/mc:latest \
  --command -- sh -c "
    mc alias set myminio http://minio.gitlab.svc.cluster.local:9000 minio minio-password &&
    mc mb myminio/gitlab-registry &&
    mc mb myminio/gitlab-lfs &&
    mc mb myminio/gitlab-artifacts &&
    mc mb myminio/gitlab-uploads &&
    mc mb myminio/gitlab-packages &&
    mc mb myminio/gitlab-backups &&
    mc mb myminio/gitlab-tmp
  "

# Config backup
kubectl apply -f "$CONFS_DIR/registry-storage.yaml"
kubectl apply -f "$CONFS_DIR/backup-secret.yaml"

# Create secrets for GitLab
kubectl create secret generic gitlab-postgresql-password \
  --namespace gitlab \
  --from-literal=postgresql-password=gitlab-password
kubectl create secret generic gitlab-redis-password \
  --namespace gitlab \
  --from-literal=redis-password=redis-password
kubectl apply -f "$CONFS_DIR/minio-secret.yaml"

# Install GitLab
helm install gitlab gitlab/gitlab \
  --namespace gitlab \
  -f "$CONFS_DIR/values.yaml" \
  --version 10.0.0
