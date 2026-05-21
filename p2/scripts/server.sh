#!/bin/sh

apt-get update
apt-get install -y curl

export INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644 --node-ip 192.168.56.110 --bind-address 192.168.56.110 --advertise-address 192.168.56.110"

curl -sfL https://get.k3s.io | sh -

while ! kubectl get nodes 2>/dev/null | grep -q "Ready"; do
  sleep 1
done

kubectl apply -f /vagrant/confs/

echo "alias k='kubectl'" >>/home/vagrant/.bashrc
