#!/bin/sh
# Usage: ./scripts/setup.sh
#
# Creates the K3d cluster, installs Argo CD, then GitLab and its dependencies
# (PostgreSQL, Redis, MinIO) in the gitlab namespace.
# Run gitlab-setup.sh afterwards, once every GitLab pod is up.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFS_DIR="$SCRIPT_DIR/../confs"

# chart versions are pinned so the bonus installs identically every time
POSTGRESQL_VERSION="18.8.4"
REDIS_VERSION="27.0.18"
GITLAB_VERSION="10.0.0"

#   Cluster
CLUSTER_MEMORY="8g"

# p3 and the bonus share the cluster name, so start from a clean one
if k3d cluster list --no-headers 2>/dev/null | grep -q '^iot '; then
    echo "Cluster 'iot' already exists, deleting it first."
    k3d cluster delete iot
fi

k3d cluster create iot --port "8888:30888@loadbalancer" --port "8443:30443@loadbalancer" --servers-memory "$CLUSTER_MEMORY"

# the subject asks for a dedicated gitlab namespace, on top of part 3's two
for ns in argocd dev gitlab; do
    kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns"
done

#   Argo CD

kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

if ! kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=600s; then
    echo "Argo CD did not become available in time, current state:" >&2
    kubectl get pods -n argocd >&2
    exit 1
fi

#   GitLab dependencies

helm repo add gitlab https://charts.gitlab.io/
helm repo update

helm upgrade --install postgresql oci://registry-1.docker.io/bitnamicharts/postgresql \
    --version "$POSTGRESQL_VERSION" \
    --namespace gitlab \
    --wait --timeout 10m \
    --set auth.username=gitlab \
    --set auth.password=gitlab-password \
    --set auth.database=gitlabhq_production \
    --set primary.persistence.size=2Gi \
    --set primary.resources.requests.memory=512Mi \
    --set primary.resources.limits.memory=1Gi \
    --set primary.livenessProbe.initialDelaySeconds=120 \
    --set primary.readinessProbe.initialDelaySeconds=120

helm upgrade --install redis oci://registry-1.docker.io/bitnamicharts/redis \
    --version "$REDIS_VERSION" \
    --namespace gitlab \
    --wait --timeout 10m \
    --set auth.password=redis-password \
    --set master.persistence.size=2Gi \
    --set replica.replicaCount=0

# MinIO is deployed by hand: the bitnami image was removed from Docker Hub
kubectl apply -f "$CONFS_DIR/minio.yaml"
kubectl rollout status deployment/minio -n gitlab --timeout=300s

# --ignore-existing keeps this step replayable
kubectl run minio-setup --rm -i --restart=Never --namespace gitlab --image quay.io/minio/mc:latest \
    --command -- sh -c "
    mc alias set myminio http://minio.gitlab.svc.cluster.local:9000 minio minio-password &&
    mc mb --ignore-existing myminio/gitlab-registry &&
    mc mb --ignore-existing myminio/gitlab-lfs &&
    mc mb --ignore-existing myminio/gitlab-artifacts &&
    mc mb --ignore-existing myminio/gitlab-uploads &&
    mc mb --ignore-existing myminio/gitlab-packages &&
    mc mb --ignore-existing myminio/gitlab-backups &&
    mc mb --ignore-existing myminio/gitlab-tmp
  "

#   Secrets

kubectl apply -f "$CONFS_DIR/registry-storage.yaml"
kubectl apply -f "$CONFS_DIR/backup-secret.yaml"
kubectl apply -f "$CONFS_DIR/minio-secret.yaml"

# 'kubectl create secret' fails when the secret is already there, so go
# through apply instead
kubectl create secret generic gitlab-postgresql-password \
    --namespace gitlab \
    --from-literal=postgresql-password=gitlab-password \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic gitlab-redis-password \
    --namespace gitlab \
    --from-literal=redis-password=redis-password \
    --dry-run=client -o yaml | kubectl apply -f -

#   GitLab

helm upgrade --install gitlab gitlab/gitlab \
    --namespace gitlab \
    -f "$CONFS_DIR/values.yaml" \
    --version "$GITLAB_VERSION"

echo ""
echo "=== Cluster ready ==="
echo "Node memory budget: $CLUSTER_MEMORY"
echo "Wait until every GitLab pod is Running or Completed (5 to 10 minutes):"
echo "  kubectl get pods -n gitlab"
echo "Then run: ./scripts/gitlab-setup.sh"
