#!/bin/sh

for vm in snourryS snourrySW; do
    VBoxManage controlvm "$vm" poweroff 2>/dev/null
    VBoxManage unregistervm "$vm" --delete 2>/dev/null
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
rm -rf "$SCRIPT_DIR/p1/.vagrant" "$SCRIPT_DIR/p2/.vagrant"
k3d cluster delete iot 2>/dev/null

echo "--- VMs ---"
VBoxManage list vms

echo "--- clusters ---"
k3d cluster list 2>/dev/null
