#!/bin/sh
# Usage: ./scripts/verify.sh   (run after 'vagrant up')
#
# Checks Part 1 against the subject: two VMs with the right hostnames, a
# dedicated IP on each, K3s in controller mode on the server and in agent
# mode on the worker, and both nodes Ready in the cluster.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.." || exit 1

SERVER="snourryS"
WORKER="snourrySW"
SERVER_IP="192.168.56.110"
WORKER_IP="192.168.56.111"

FAILED=0

ok() { printf '  [ OK ] %s\n' "$1"; }
ko() {
    printf '  [FAIL] %s\n' "$1"
    FAILED=1
}

# run a command inside a VM, dropping vagrant's own chatter
vm() {
    vagrant ssh "$1" -c "$2" </dev/null 2>/dev/null | tr -d '\r'
}

echo "=== Virtual machines ==="
for m in "$SERVER" "$WORKER"; do
    if vagrant status "$m" 2>/dev/null | grep -q "$m *running"; then
        ok "$m is running"
    else
        ko "$m is not running (try 'vagrant up')"
        FAILED=1
    fi
done

if [ "$FAILED" -ne 0 ]; then
    echo ""
    echo "=== Part 1 KO: bring the machines up first ==="
    exit 1
fi

echo "=== Hostnames ==="
for m in "$SERVER" "$WORKER"; do
    h=$(vm "$m" hostname)
    if [ "$h" = "$m" ]; then
        ok "$m hostname is '$h'"
    else
        ko "$m hostname is '$h', expected '$m'"
    fi
done

echo "=== Dedicated IPs ==="
check_ip() {
    out=$(vm "$1" "ip -o -4 addr show")
    line=$(echo "$out" | grep -F "$2/")
    if [ -n "$line" ]; then
        ok "$1 has $2 on interface $(echo "$line" | awk '{print $2}')"
    else
        ko "$1 does not carry $2"
        echo "$out" | sed 's/^/         raw: /'
    fi
}
check_ip "$SERVER" "$SERVER_IP"
check_ip "$WORKER" "$WORKER_IP"

echo "=== K3s mode ==="
s=$(vm "$SERVER" "systemctl is-active k3s")
if [ "$s" = "active" ]; then
    ok "$SERVER runs the k3s service (controller mode)"
else
    ko "$SERVER: k3s service is '$s'"
fi

w=$(vm "$WORKER" "systemctl is-active k3s-agent")
if [ "$w" = "active" ]; then
    ok "$WORKER runs the k3s-agent service (agent mode)"
else
    ko "$WORKER: k3s-agent service is '$w'"
fi

echo "=== kubectl ==="
if [ -n "$(vm "$SERVER" "command -v kubectl")" ]; then
    ok "kubectl is installed on $SERVER"
else
    ko "kubectl is missing on $SERVER"
fi

echo "=== Cluster ==="
nodes=$(vm "$SERVER" "kubectl get nodes -o wide --no-headers")

if [ -z "$nodes" ]; then
    ko "kubectl returned no node"
else
    echo "$nodes" | sed 's/^/         /'

    count=$(echo "$nodes" | wc -l)
    if [ "$count" -eq 2 ]; then
        ok "the cluster has 2 nodes"
    else
        ko "the cluster has $count node(s), expected 2"
    fi

    # kubelet lowercases the hostname, so the node names are snourrys / snourrysw
    for pair in "$SERVER $SERVER_IP" "$WORKER $WORKER_IP"; do
        name=$(echo "$pair" | awk '{print $1}')
        ip=$(echo "$pair" | awk '{print $2}')
        row=$(echo "$nodes" | grep -i "^$name ")

        if [ -z "$row" ]; then
            ko "node $name is absent from the cluster"
            continue
        fi

        status=$(echo "$row" | awk '{print $2}')
        if [ "$status" = "Ready" ]; then
            ok "node $name is Ready"
        else
            ko "node $name is '$status'"
        fi

        if echo "$row" | grep -q " $ip "; then
            ok "node $name is registered with $ip"
        else
            ko "node $name is not registered with $ip"
        fi
    done
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "=== Part 1 OK ==="
else
    echo "=== Part 1 KO ==="
fi
exit "$FAILED"
