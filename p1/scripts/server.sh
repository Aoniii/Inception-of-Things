#!/bin/sh

apt-get update
apt-get install -y curl

export INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644 --node-ip 192.168.56.110 --bind-address 192.168.56.110 --advertise-address 192.168.56.110"

# Install K3s in server (controller) mode
curl -sfL https://get.k3s.io | sh -

# Wait for the node-token to be generated
while [ ! -f /var/lib/rancher/k3s/server/node-token ]; do
  sleep 1
done

# Copy the token to the shared vagrant folder so the worker can read it
cp /var/lib/rancher/k3s/server/node-token /vagrant/node-token
