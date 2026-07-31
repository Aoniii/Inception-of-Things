#!/bin/sh
# Usage: ./scripts/clean.sh
#
# Deletes the K3d cluster created by setup.sh. Docker, kubectl and K3d stay
# installed: use uninstall.sh to remove them too.

set -e

if ! command -v k3d >/dev/null 2>&1; then
    echo "k3d is not installed, nothing to clean."
    exit 0
fi

if k3d cluster list --no-headers 2>/dev/null | grep -q '^iot '; then
    k3d cluster delete iot
    echo "Cluster 'iot' deleted."
else
    echo "No cluster named 'iot', nothing to clean."
fi

# k3d drops its own network, volumes and kubeconfig entry: check nothing is left
left=$(docker ps -a --filter "name=k3d-iot" --format '{{.Names}}' 2>/dev/null)
if [ -n "$left" ]; then
    echo "WARNING: some containers are still there:" >&2
    echo "$left" >&2
fi
