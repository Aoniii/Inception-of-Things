#!/bin/sh
# Usage: ./scripts/verify.sh   (run after 'vagrant up')
#
# Checks Part 2 against the subject: one VM in K3s server mode, three web
# applications with 1/3/1 replicas, and host-based routing through the Ingress
# (app1.com -> app-1, app2.com -> app-2, anything else -> app-3).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.." || exit 1

SERVER="snourryS"
SERVER_IP="192.168.56.110"

FAILED=0

ok() { printf '  [ OK ] %s\n' "$1"; }
ko() {
    printf '  [FAIL] %s\n' "$1"
    FAILED=1
}

vm() {
    vagrant ssh "$SERVER" -c "$1" </dev/null 2>/dev/null | tr -d '\r'
}

echo "=== Virtual machine ==="
if vagrant status "$SERVER" 2>/dev/null | grep -q "$SERVER *running"; then
    ok "$SERVER is running"
else
    ko "$SERVER is not running (try 'vagrant up')"
    echo ""
    echo "=== Part 2 KO: bring the machine up first ==="
    exit 1
fi

h=$(vm hostname)
if [ "$h" = "$SERVER" ]; then
    ok "hostname is '$h'"
else
    ko "hostname is '$h', expected '$SERVER'"
fi

out=$(vm "ip -o -4 addr show")
line=$(echo "$out" | grep -F "$SERVER_IP/")
if [ -n "$line" ]; then
    ok "$SERVER_IP is set on interface $(echo "$line" | awk '{print $2}')"
else
    ko "$SERVER does not carry $SERVER_IP"
    echo "$out" | sed 's/^/         raw: /'
fi

echo "=== K3s ==="
s=$(vm "systemctl is-active k3s")
if [ "$s" = "active" ]; then
    ok "k3s runs in server mode"
else
    ko "k3s service is '$s'"
fi

# Traefik is deployed by a job on first boot, it can take a few minutes
i=0
while [ "$i" -lt 60 ]; do
    traefik=$(vm "kubectl get pods -n kube-system --no-headers")
    echo "$traefik" | grep traefik | grep -q Running && break
    i=$((i + 1))
    sleep 5
done
if echo "$traefik" | grep traefik | grep -q Running; then
    ok "Traefik ingress controller is Running"
else
    ko "Traefik is not Running"
fi

echo "=== Deployments ==="
# let the pods settle before judging them: images have to be pulled first
vm "kubectl wait --for=condition=Available deployment --all --timeout=300s" >/dev/null 2>&1

deploys=$(vm "kubectl get deployments --no-headers")
echo "$deploys" | sed 's/^/         /'

check_deploy() {
    row=$(echo "$deploys" | grep "^$1 ")
    if [ -z "$row" ]; then
        ko "deployment $1 is missing"
        return
    fi
    ready=$(echo "$row" | awk '{print $2}')
    if [ "$ready" = "$2" ]; then
        ok "$1 is $ready"
    else
        ko "$1 is $ready, expected $2"
    fi
}
check_deploy app-1 "1/1"
check_deploy app-2 "3/3"
check_deploy app-3 "1/1"

echo "=== Services ==="
svcs=$(vm "kubectl get services --no-headers")
for s in app-1 app-2 app-3; do
    if echo "$svcs" | grep -q "^$s "; then
        ok "service $s exists"
    else
        ko "service $s is missing"
    fi
done

echo "=== Ingress ==="
ing=$(vm "kubectl get ingress --no-headers")
if [ -z "$ing" ]; then
    ko "no ingress found"
else
    echo "$ing" | sed 's/^/         /'
    for host in app1.com app2.com; do
        if echo "$ing" | grep -q "$host"; then
            ok "ingress declares $host"
        else
            ko "ingress does not declare $host"
        fi
    done
fi

echo "=== Host-based routing (from this machine) ==="
if ! command -v curl >/dev/null 2>&1; then
    ko "curl is missing on this host, cannot test the routing"
else
    http_get() {
        if [ -n "$1" ]; then
            curl -s -m 5 -H "Host: $1" "http://$SERVER_IP/"
        else
            curl -s -m 5 "http://$SERVER_IP/"
        fi
    }

    check_route() {
        # $1 = Host header (empty for the default route), $2 = expected text, $3 = label
        i=0
        while [ "$i" -lt 20 ]; do
            body=$(http_get "$1")
            if echo "$body" | grep -q "$2"; then
                ok "$3 serves '$2'"
                return
            fi
            i=$((i + 1))
            sleep 3
        done
        ko "$3 did not serve '$2'"
        echo "$body" | head -3 | sed 's/^/         raw: /'
    }

    check_route "app1.com" "Hello from app-1" "Host app1.com"
    check_route "app2.com" "Hello from app-2" "Host app2.com"
    check_route "" "Hello from app-3" "no Host (default)"
fi

echo "=== app-2 replicas ==="
pods=$(vm "kubectl get pods -l app=app-2 --no-headers")
echo "$pods" | sed 's/^/         /'
running=$(echo "$pods" | grep -c Running)
if [ "$running" -eq 3 ]; then
    ok "app-2 has 3 pods Running"
else
    ko "app-2 has $running pod(s) Running, expected 3"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "=== Part 2 OK ==="
else
    echo "=== Part 2 KO ==="
fi
exit "$FAILED"
