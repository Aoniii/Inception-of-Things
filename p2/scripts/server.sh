#!/bin/sh

set -e

if ! command -v curl >/dev/null 2>&1; then
    apt-get update
    apt-get install -y curl
fi

export INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644 --node-ip 192.168.56.110 --bind-address 192.168.56.110 --advertise-address 192.168.56.110"
export INSTALL_K3S_VERSION="v1.36.2+k3s1"

curl -sfL https://get.k3s.io | sh -

while ! kubectl get nodes 2>/dev/null | grep -q "Ready"; do
    sleep 1
done

kubectl apply -f /vagrant/confs/

grep -q "alias k=" /home/vagrant/.bashrc || echo "alias k='kubectl'" >>/home/vagrant/.bashrc
