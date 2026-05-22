#!/bin/sh
# Usage: sudo ./install.sh

set -e

apt update
apt install -y ca-certificates curl

echo "=== Installing Docker ==="
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  . /etc/os-release
  case "$ID" in
  ubuntu)
    DOCKER_REPO="https://download.docker.com/linux/ubuntu"
    CODENAME="${VERSION_CODENAME:-noble}"
    ;;
  debian)
    DOCKER_REPO="https://download.docker.com/linux/debian"
    CODENAME="${VERSION_CODENAME:-bookworm}"
    ;;
  *)
    echo "Unsupported OS: $ID"
    exit 1
    ;;
  esac

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] $DOCKER_REPO $CODENAME stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null

  apt update
  apt install -y docker-ce docker-ce-cli containerd.io

  echo "Docker installed."
else
  echo "Docker already installed."
fi

echo "=== Installing kubectl ==="

echo "=== Installing K3d ==="

echo ""
echo "=== Installing complete ==="
echo "Docker: $(docker --version)"
echo "kubectl: "
echo "K3d: "
