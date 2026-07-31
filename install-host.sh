#!/bin/sh
# Usage: sudo ./install_host.sh
# Installs what Parts 1 and 2 need on the host VM: VirtualBox and Vagrant.
# Parts 3 and bonus use their own script (p3/scripts/install.sh, bonus/scripts/install.sh).

set -e

VAGRANT_VERSION="2.4.9"
VBOX_VERSION="7.1"

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
apt-get install -y wget curl net-tools

#   VirtualBox

echo "=== Installing VirtualBox ==="
if ! command -v vboxmanage >/dev/null 2>&1; then
    # Ubuntu 24.04 ships VirtualBox 7.0.16, whose kernel modules fail to build
    # against 7.x kernels: modpost rejects vboxdrv for using the KVM symbols
    # without MODULE_IMPORT_NS. Oracle's own builds handle recent kernels.
    install -m 0755 -d /etc/apt/keyrings
    wget -4 -qO- https://www.virtualbox.org/download/oracle_vbox_2016.asc | gpg --dearmor -o /etc/apt/keyrings/oracle-virtualbox.gpg
    chmod a+r /etc/apt/keyrings/oracle-virtualbox.gpg

    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/oracle-virtualbox.gpg] https://download.virtualbox.org/virtualbox/debian $VERSION_CODENAME contrib" \
        >/etc/apt/sources.list.d/oracle-virtualbox.list

    apt-get update

    # the module build needs a compiler and the running kernel's headers
    apt-get install -y build-essential dkms "linux-headers-$(uname -r)"
    apt-get install -y "virtualbox-${VBOX_VERSION}"

    echo "VirtualBox installed."
else
    echo "VirtualBox already installed."
fi

#   Vagrant

echo "=== Installing Vagrant ==="
# Ubuntu ships an older Vagrant in universe, so take the .deb from HashiCorp
if ! command -v vagrant >/dev/null 2>&1; then
    wget -4 --timeout=30 --tries=3 -O /tmp/vagrant.deb "https://releases.hashicorp.com/vagrant/${VAGRANT_VERSION}/vagrant_${VAGRANT_VERSION}-1_amd64.deb"
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
