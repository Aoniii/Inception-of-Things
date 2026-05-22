#!/bin/sh
# Usage: sudo ./uninstall.sh

set -e

echo "=== Uninstalling Docker ==="
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker already uninstalled."
else
  apt remove -y docker-ce docker-ce-cli containerd.io
  apt autoremove -y
  rm -rf /var/lib/docker/
  rm -rf /var/lib/containerd
  rm -f /etc/apt/sources.list.d/docker.list
  rm -f /etc/apt/keyrings/docker.asc

  echo "Docker uninstalled."
fi

echo "=== Uninstalling kubectl ==="

echo "=== Uninstalling K3d ==="
