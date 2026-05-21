#!/bin/sh
# Usage: sudo ./install_host.sh

set -e

apt-get update
apt-get install -y virtualbox virtualbox-dkms

wget -O /tmp/vagrant.deb https://releases.hashicorp.com/vagrant/2.4.9/vagrant_2.4.9-1_amd64.deb
dpkg -i /tmp/vagrant.deb
rm /tmp/vagrant.deb

apt-get install -y net-tools

echo "VirtualBox: $(vboxmanage --version)"
echo "Vagrant: $(vagrant --version)"
