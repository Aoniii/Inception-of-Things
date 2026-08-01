#!/bin/sh

set -e

if ! command -v curl >/dev/null 2>&1; then
    apt-get update
    apt-get install -y curl
fi

export INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644 --node-ip 192.168.56.110 --bind-address 192.168.56.110 --advertise-address 192.168.56.110 --disable traefik --disable metrics-server"
export INSTALL_K3S_VERSION="v1.36.2+k3s1"

# Install K3s in server (controller) mode
curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh
sh /tmp/k3s-install.sh
cp /usr/local/bin/k3s /vagrant/k3s
cp /tmp/k3s-install.sh /vagrant/k3s-install.sh

# Wait for the node-token to be generated
while [ ! -f /var/lib/rancher/k3s/server/node-token ]; do
    sleep 1
done

# Copy the token to the shared vagrant folder so the worker can read it
cp /var/lib/rancher/k3s/server/node-token /vagrant/node-token

grep -q "alias k=" /home/vagrant/.bashrc || echo "alias k='kubectl'" >>/home/vagrant/.bashrc
