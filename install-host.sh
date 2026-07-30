#!/bin/sh
# Usage: sudo ./install_host.sh
# Installs what Parts 1 and 2 need on the host VM: VirtualBox and Vagrant.
# Parts 3 and bonus use their own script (p3/scripts/install.sh, bonus/scripts/install.sh).

set -e

VAGRANT_VERSION="2.4.9"

#   Preflight

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root: sudo ./install-host.sh" >&2
    exit 1
fi

. /etc/os-release
if [ "$ID" != "ubuntu" ] || [ "$VERSION_ID" != "24.04" ]; then
    echo "This project targets Ubuntu 24.04 LTS only (found: $PRETTY_NAME)." >&2
    exit 1
fi

# VirtualBox cannot start a VM without the CPU virtualization extensions,
# so this host VM needs nested virtualization enabled on its own hypervisor
if ! grep -qE 'vmx|svm' /proc/cpuinfo; then
    echo "ERROR: no vmx/svm flag in /proc/cpuinfo." >&2
    echo "Enable nested virtualization on the hypervisor running this VM, then re-run." >&2
    exit 1
fi

apt-get update
apt-get install -y wget net-tools

#   VirtualBox

echo "=== Installing VirtualBox ==="
if ! command -v vboxmanage >/dev/null 2>&1; then
    # On Ubuntu, virtualbox lives in the multiverse component
    if ! apt-cache policy virtualbox | grep -q 'Candidate: [0-9]'; then
        echo "Package 'virtualbox' has no installation candidate." >&2
        echo "Enable multiverse: add-apt-repository multiverse && apt-get update" >&2
        exit 1
    fi

    # dkms needs a compiler and the running kernel's headers to build vboxdrv
    apt-get install -y build-essential dkms
    apt-get install -y "linux-headers-$(uname -r)" || apt-get install -y linux-headers-generic

    apt-get install -y virtualbox virtualbox-dkms

    echo "VirtualBox installed."
else
    echo "VirtualBox already installed."
fi

if ! lsmod | grep -q '^vboxdrv'; then
    if ! modprobe vboxdrv 2>/dev/null; then
        echo "ERROR: the vboxdrv module is not loaded." >&2
        echo "Inspect the dkms build with 'dkms status', then rebuild with '/sbin/vboxconfig'." >&2
        exit 1
    fi
fi

#   Vagrant

echo "=== Installing Vagrant ==="
# Ubuntu ships an older Vagrant in universe, so take the .deb from HashiCorp
if ! command -v vagrant >/dev/null 2>&1; then
    wget -O /tmp/vagrant.deb "https://releases.hashicorp.com/vagrant/${VAGRANT_VERSION}/vagrant_${VAGRANT_VERSION}-1_amd64.deb"
    dpkg -i /tmp/vagrant.deb || apt-get install -f -y
    rm -f /tmp/vagrant.deb
    echo "Vagrant installed."
else
    echo "Vagrant already installed."
fi

#   Summary

echo ""
echo "=== Installing complete ==="
echo "VirtualBox: $(vboxmanage --version)"
echo "Vagrant:    $(vagrant --version)"
echo "vboxdrv:    loaded"
