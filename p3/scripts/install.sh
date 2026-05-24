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

  usermod -aG docker $SUDO_USER
  chmod 666 /var/run/docker.sock

  echo "Docker installed."
else
  echo "Docker already installed."
fi

echo "=== Installing kubectl ==="
if ! command -v kubectl >/dev/null 2>&1; then
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm kubectl
  echo "kubectl installed."
else
  echo "kubectl already installed."
fi

echo "=== Installing K3d ==="
if ! command -v k3d >/dev/null 2>&1; then
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
  echo "K3d installed."
else
  echo "K3d already installed."
fi

echo ""
echo "=== Installing complete ==="
echo "Docker: $(docker --version)"
echo "kubectl: $(kubectl version --client | sed '1{N;s/\n/, /}')"
echo "K3d: $(k3d --version | sed '1{N;s/\n/, /}')"
