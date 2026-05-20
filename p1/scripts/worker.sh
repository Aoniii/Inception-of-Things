#!/bin/sh

apt-get update
apt-get install -y curl

export INSTALL_K3S_EXEC="agent --node-ip 192.168.56.111"
export K3S_URL="https://192.168.56.110:6443"
export K3S_TOKEN=$(cat /vagrant/node-token)

# Install K3s in agent (worker) mode
curl -sfL https://get.k3s.io | sh -
