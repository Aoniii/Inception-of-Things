#!/bin/sh
# Usage: sudo ./scripts/uninstall.sh
# Target: Ubuntu 24.04 LTS
#
# Removes what install.sh installed: Docker, kubectl, K3d and Helm.

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root: sudo ./scripts/uninstall.sh" >&2
    exit 1
fi

. /etc/os-release
if [ "$ID" != "ubuntu" ] || [ "$VERSION_ID" != "24.04" ]; then
    echo "This project targets Ubuntu 24.04 LTS only (found: $PRETTY_NAME)." >&2
    exit 1
fi

# drop the cluster while Docker and K3d are still around, otherwise its
# containers and its kubeconfig entry are left behind
if command -v k3d >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    if k3d cluster list --no-headers 2>/dev/null | grep -q '^iot '; then
        echo "=== Deleting the K3d cluster ==="
        k3d cluster delete iot
    fi
fi

echo "=== Uninstalling Helm ==="
if command -v helm >/dev/null 2>&1; then
    rm -f /usr/local/bin/helm

    # setup.sh added the gitlab chart repo under the calling user, not root
    if [ -n "$SUDO_USER" ]; then
        HOME_DIR=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        if [ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ]; then
            rm -rf "$HOME_DIR/.config/helm" "$HOME_DIR/.cache/helm"
        fi
    fi

    echo "Helm uninstalled."
else
    echo "Helm already uninstalled."
fi

echo "=== Uninstalling K3d ==="
if command -v k3d >/dev/null 2>&1; then
    rm -f /usr/local/bin/k3d
    echo "K3d uninstalled."
else
    echo "K3d already uninstalled."
fi

echo "=== Uninstalling kubectl ==="
if command -v kubectl >/dev/null 2>&1; then
    rm -f /usr/local/bin/kubectl
    echo "kubectl uninstalled."
else
    echo "kubectl already uninstalled."
fi

echo "=== Uninstalling Docker ==="
if command -v docker >/dev/null 2>&1; then
    # undo the group membership granted by install.sh, before the package goes
    if [ -n "$SUDO_USER" ] && id -nG "$SUDO_USER" 2>/dev/null | grep -qw docker; then
        gpasswd -d "$SUDO_USER" docker
    fi

    apt-get purge -y docker-ce docker-ce-cli containerd.io
    apt-get autoremove -y

    # this wipes every image, container and volume on the machine
    rm -rf /var/lib/docker /var/lib/containerd

    rm -f /etc/apt/sources.list.d/docker.list
    rm -f /etc/apt/keyrings/docker.asc
    apt-get update

    echo "Docker uninstalled."
else
    echo "Docker already uninstalled."
fi

echo ""
echo "=== Uninstalling complete ==="

# the shell caches the path of the binaries it has run, and this script ran
# docker and k3d above: drop that cache before reporting what is left
hash -r 2>/dev/null || true

report() {
    label="$1"
    bin="$2"
    shift 2
    if command -v "$bin" >/dev/null 2>&1; then
        printf '%-9s %s\n' "$label" "$("$@" 2>/dev/null | head -1)"
    else
        printf '%-9s %s\n' "$label" "not installed"
    fi
}

report "Docker:" docker docker --version
report "kubectl:" kubectl kubectl version --client
report "K3d:" k3d k3d version
report "Helm:" helm helm version --short
