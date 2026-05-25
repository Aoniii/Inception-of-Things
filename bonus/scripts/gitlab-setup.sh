#!/bin/sh
# Usage: ./gitlab-setup.sh
# Run after setup.sh when all GitLab pods are running

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFS_DIR="$SCRIPT_DIR/../confs"

# Get GitLab root password
GITLAB_PASSWORD=$(kubectl get secret gitlab-gitlab-initial-root-password -n gitlab -o jsonpath="{.data.password}" | base64 -d)
echo "GitLab root password: $GITLAB_PASSWORD"

# Add gitlab.gitlab.local to /etc/hosts if not already present
if ! grep -q "gitlab.gitlab.local" /etc/hosts; then
  echo "127.0.0.1 gitlab.gitlab.local" | sudo tee -a /etc/hosts
fi

# Wait for GitLab to be accessible
echo "Waiting for GitLab to be accessible..."
until curl -ks --fail https://gitlab.gitlab.local:8443/users/sign_in >/dev/null 2>&1; do
  sleep 10
done
echo "GitLab is ready!"

# Wait for GitLab webservice to be fully ready
echo "Waiting for GitLab webservice..."
kubectl wait --for=condition=Ready pod -l app=webservice -n gitlab --timeout=600s

# Clone GitHub repo and push to GitLab
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"
git clone https://github.com/Aoniii/snourry-iot.git
cd snourry-iot
git remote add gitlab https://root:${GITLAB_PASSWORD}@gitlab.gitlab.local:8443/root/snourry-iot.git
GIT_SSL_NO_VERIFY=true git push gitlab main

# Make the project public
kubectl exec -n gitlab deploy/gitlab-toolbox -- gitlab-rails runner "p = Project.find(1); p.visibility_level = 20; p.save!; puts p.visibility_level"

# Wait for visibility change to propagate
sleep 30

# Delete old app if exists and recreate
kubectl delete application wil-playground -n argocd 2>/dev/null || true
sleep 10
kubectl apply -f "$CONFS_DIR/argocd-app.yaml"

# Wait for sync
echo "Waiting for Argo CD to sync..."
sleep 30

# Cleanup temp dir
rm -rf "$TEMP_DIR"

echo ""
echo "=== GitLab setup complete ==="
echo "GitLab UI: https://gitlab.gitlab.local:8443"
echo "Login: root / $GITLAB_PASSWORD"
echo "Argo CD now watches GitLab repo for deployments"
