#!/bin/sh

for vm in snourryS snourrySW; do
    VBoxManage controlvm "$vm" poweroff 2>/dev/null
    VBoxManage unregistervm "$vm" --delete 2>/dev/null
done

rm -rf ~/iot/p1/.vagrant ~/iot/p2/.vagrant
k3d cluster delete iot 2>/dev/null

echo "--- VMs ---"
VBoxManage list vms

echo "--- clusters ---"
k3d cluster list 2>/dev/null
