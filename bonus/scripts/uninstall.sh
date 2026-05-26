#!/bin/sh
# Usage: sudo ./uninstall.sh

set -e

echo "=== Uninstalling Docker ==="
if command -v docker >/dev/null 2>&1; then
  apt remove -y docker-ce docker-ce-cli containerd.io
  apt autoremove -y
  rm -rf /var/lib/docker/
  rm -rf /var/lib/containerd
  rm -f /etc/apt/sources.list.d/docker.list
  rm -f /etc/apt/keyrings/docker.asc

  gpasswd -d $SUDO_USER docker || true

  echo "Docker uninstalled."
else
  echo "Docker already uninstalled."
fi

echo "=== Uninstalling kubectl ==="
if command -v kubectl >/dev/null 2>&1; then
  rm -f /usr/local/bin/kubectl
  echo "kubectl uninstalled."
else
  echo "kubectl already uninstalled."
fi

echo "=== Uninstalling K3d ==="
if command -v k3d >/dev/null 2>&1; then
  rm -f /usr/local/bin/k3d
  echo "K3d uninstalled."
else
  echo "K3d already uninstalled."
fi

echo "=== Uninstalling helm ==="
if command -v helm >/dev/null 2>&1; then
  rm -f /usr/local/bin/helm
  echo "helm uninstalled."
else
  echo "helm already uninstalled."
fi
