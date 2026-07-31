#!/bin/sh
# Usage: ./scripts/clean.sh
#
# Deletes the K3d cluster created by setup.sh, and undoes what setup.sh and
# gitlab-setup.sh changed outside the cluster. Docker, kubectl, K3d and Helm
# stay installed: use uninstall.sh to remove them too.

set -e

GITLAB_HOST="gitlab.gitlab.local"

if command -v k3d >/dev/null 2>&1; then
    if k3d cluster list --no-headers 2>/dev/null | grep -q '^iot '; then
        k3d cluster delete iot
        echo "Cluster 'iot' deleted."
    else
        echo "No cluster named 'iot', nothing to delete."
    fi
else
    echo "k3d is not installed, no cluster to delete."
fi

# setup.sh added the gitlab chart repository
if command -v helm >/dev/null 2>&1 && helm repo list 2>/dev/null | grep -q '^gitlab'; then
    helm repo remove gitlab
    echo "Helm repository 'gitlab' removed."
fi

# gitlab-setup.sh added this line so the browser could reach the GitLab ingress
if grep -q "$GITLAB_HOST" /etc/hosts 2>/dev/null; then
    echo "Removing $GITLAB_HOST from /etc/hosts (sudo needed)."
    ESCAPED=$(echo "$GITLAB_HOST" | sed 's/\./\\./g')
    sudo sed -i "/$ESCAPED/d" /etc/hosts
fi

# k3d drops its own network, volumes and kubeconfig entry: check nothing is left
if command -v docker >/dev/null 2>&1; then
    left=$(docker ps -a --filter "name=k3d-iot" --format '{{.Names}}' 2>/dev/null)
    if [ -n "$left" ]; then
        echo "WARNING: some containers are still there:" >&2
        echo "$left" >&2
    fi
fi

echo "Clean complete."
