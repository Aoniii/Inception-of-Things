#!/bin/sh
# Usage: sudo ./scripts/install.sh
# Target: Ubuntu 24.04 LTS
#
# Installs what Part 3 needs: Docker, kubectl and K3d.

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root: sudo ./scripts/install.sh" >&2
    exit 1
fi

. /etc/os-release
if [ "$ID" != "ubuntu" ] || [ "$VERSION_ID" != "24.04" ]; then
    echo "This project targets Ubuntu 24.04 LTS only (found: $PRETTY_NAME)." >&2
    exit 1
fi

apt-get update
apt-get install -y ca-certificates curl

echo "=== Installing Docker ==="
if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    curl -4 -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" >/etc/apt/sources.list.d/docker.list

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io

    if [ -n "$SUDO_USER" ]; then
        usermod -aG docker "$SUDO_USER"
    fi

    echo "Docker installed."
else
    echo "Docker already installed."
fi

# group membership only applies to a new login session, so open the socket now
# to keep setup.sh usable in the same shell
if [ -S /var/run/docker.sock ]; then
    chmod 666 /var/run/docker.sock
fi

echo "=== Installing kubectl ==="
if ! command -v kubectl >/dev/null 2>&1; then
    TMP=$(mktemp -d)
    KVER=$(curl -4 -L -s https://dl.k8s.io/release/stable.txt)
    curl -4 -Lo "$TMP/kubectl" "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
    install -o root -g root -m 0755 "$TMP/kubectl" /usr/local/bin/kubectl
    rm -rf "$TMP"
    echo "kubectl installed."
else
    echo "kubectl already installed."
fi

echo "=== Installing K3d ==="
if ! command -v k3d >/dev/null 2>&1; then
    curl -4 -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
    echo "K3d installed."
else
    echo "K3d already installed."
fi

echo ""
echo "=== Installing complete ==="
echo "Docker:  $(docker --version)"
echo "kubectl: $(kubectl version --client 2>/dev/null | head -1)"
echo "K3d:     $(k3d version | head -1)"
