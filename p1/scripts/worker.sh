#!/bin/sh

set -e

if ! command -v curl >/dev/null 2>&1; then
    apt-get update
    apt-get install -y curl
fi

# The token is written by the server into the shared /vagrant folder
if [ ! -f /vagrant/node-token ]; then
    echo "node-token not found: bring up the server first (vagrant up snourryS)" >&2
    exit 1
fi

export INSTALL_K3S_EXEC="agent --node-ip 192.168.56.111"
export INSTALL_K3S_VERSION="v1.36.2+k3s1"
export K3S_URL="https://192.168.56.110:6443"
export K3S_TOKEN=$(cat /vagrant/node-token)

# Install K3s in agent (worker) mode
if [ -f /vagrant/k3s ]; then
    install -m 755 /vagrant/k3s /usr/local/bin/k3s
    export INSTALL_K3S_SKIP_DOWNLOAD=true
    sh /vagrant/k3s-install.sh
else
    curl -sfL https://get.k3s.io | sh -
fi

grep -q "alias k=" /home/vagrant/.bashrc || echo "alias k='kubectl'" >>/home/vagrant/.bashrc
