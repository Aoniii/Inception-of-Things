#!/bin/sh
# Usage: ./scripts/gitlab-setup.sh
#
# Pushes the manifests to the local GitLab, makes the project public, and
# points Argo CD at it instead of GitHub.
# Run after setup.sh, once every GitLab pod is Running or Completed.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFS_DIR="$SCRIPT_DIR/../confs"

GITLAB_HOST="gitlab.gitlab.local"
GITLAB_URL="https://$GITLAB_HOST:8443"
GITLAB_INTERNAL="http://gitlab-webservice-default.gitlab.svc.cluster.local:8181"
SOURCE_REPO="https://github.com/Aoniii/snourry-iot.git"
PROJECT_PATH="root/snourry-iot"

# bounded wait: give up loudly instead of hanging forever
wait_for() {
    label="$1"
    timeout="$2"
    cmd="$3"
    elapsed=0
    echo "Waiting for $label..."
    while [ "$elapsed" -lt "$timeout" ]; do
        if sh -c "$cmd" >/dev/null 2>&1; then
            echo "$label: ready."
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo "$label: still not ready after ${timeout}s, giving up." >&2
    return 1
}

#   Checks

if ! kubectl get namespace gitlab >/dev/null 2>&1; then
    echo "The gitlab namespace does not exist, run ./scripts/setup.sh first." >&2
    exit 1
fi

GITLAB_PASSWORD=$(kubectl get secret gitlab-gitlab-initial-root-password \
    -n gitlab -o jsonpath="{.data.password}" 2>/dev/null | base64 -d)

if [ -z "$GITLAB_PASSWORD" ]; then
    echo "Could not read the GitLab root password, is GitLab installed yet?" >&2
    exit 1
fi

if ! grep -q "$GITLAB_HOST" /etc/hosts; then
    echo "Adding $GITLAB_HOST to /etc/hosts (sudo needed)."
    echo "127.0.0.1 $GITLAB_HOST" | sudo tee -a /etc/hosts >/dev/null
fi

#   Wait for GitLab

kubectl wait --for=condition=Ready pod -l app=webservice -n gitlab --timeout=900s

wait_for "the GitLab UI on $GITLAB_URL" 900 \
    "curl -ks --fail $GITLAB_URL/users/sign_in"

#   Push the manifests to GitLab

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

git clone "$SOURCE_REPO" "$TEMP_DIR/repo"
cd "$TEMP_DIR/repo"

# GitLab creates the project on the first push
git remote add gitlab "https://root:${GITLAB_PASSWORD}@${GITLAB_HOST}:8443/${PROJECT_PATH}.git"
GIT_SSL_NO_VERIFY=true git push gitlab main

cd "$SCRIPT_DIR"

#   Make the project public so Argo CD can clone it anonymously

# look the project up by path: its id is not guaranteed to be 1
kubectl exec -n gitlab deploy/gitlab-toolbox -- gitlab-rails runner \
    "p = Project.find_by_full_path('$PROJECT_PATH'); raise 'project $PROJECT_PATH not found' if p.nil?; p.visibility_level = 20; p.save!; puts p.visibility_level"

#   Point Argo CD at GitLab

kubectl delete application wil-playground -n argocd 2>/dev/null || true

kubectl apply -f "$CONFS_DIR/argocd-app.yaml"

wait_for "Argo CD to sync the application" 600 \
    "kubectl get application wil-playground -n argocd -o jsonpath='{.status.sync.status}' | grep -q Synced"

wait_for "the application pod in the dev namespace" 300 \
    "kubectl get pods -n dev --no-headers | grep -q Running"

echo ""
echo "=== GitLab setup complete ==="
echo "GitLab UI: $GITLAB_URL"
echo "Login:     root / $GITLAB_PASSWORD"
echo "Argo CD now watches the local GitLab instead of GitHub."
