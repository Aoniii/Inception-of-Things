#!/bin/sh
# Usage: ./scripts/verify.sh   (run after 'setup.sh')
#
# Checks Part 3 against the subject: a K3d cluster, the two namespaces argocd
# and dev, Argo CD deploying the application from the public GitHub repository,
# and the application answering on port 8888.

APP="wil-playground"
CLUSTER="iot"
URL="http://localhost:8888/"

FAILED=0

ok() { printf '  [ OK ] %s\n' "$1"; }
ko() {
    printf '  [FAIL] %s\n' "$1"
    FAILED=1
}

echo "=== Prerequisites ==="
for bin in docker kubectl k3d; do
    if command -v "$bin" >/dev/null 2>&1; then
        ok "$bin is installed"
    else
        ko "$bin is missing (run 'sudo ./scripts/install.sh')"
    fi
done

if docker info >/dev/null 2>&1; then
    ok "the Docker daemon is reachable"
else
    ko "cannot talk to the Docker daemon"
fi

if [ "$FAILED" -ne 0 ]; then
    echo ""
    echo "=== Part 3 KO: fix the prerequisites first ==="
    exit 1
fi

echo "=== Cluster ==="
if k3d cluster list --no-headers 2>/dev/null | grep -q "^$CLUSTER "; then
    ok "the K3d cluster '$CLUSTER' exists"
else
    ko "no K3d cluster named '$CLUSTER' (run './scripts/setup.sh')"
    echo ""
    echo "=== Part 3 KO ==="
    exit 1
fi

nodes=$(kubectl get nodes --no-headers 2>/dev/null)
echo "$nodes" | sed 's/^/         /'
if echo "$nodes" | awk '{print $2}' | grep -q '^Ready$'; then
    ok "the cluster node is Ready"
else
    ko "no Ready node in the cluster"
fi

echo "=== Namespaces ==="
# the subject asks for two: one for Argo CD, one named dev
for ns in argocd dev; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        ok "namespace $ns exists"
    else
        ko "namespace $ns is missing"
    fi
done

echo "=== Argo CD ==="
i=0
while [ "$i" -lt 20 ]; do
    pods=$(kubectl get pods -n argocd --no-headers 2>/dev/null)
    total=$(echo "$pods" | grep -c .)
    running=$(echo "$pods" | awk '{print $3}' | grep -c '^Running$')
    if [ "$total" -gt 0 ] && [ "$running" -eq "$total" ]; then
        break
    fi
    i=$((i + 1))
    sleep 6
done

if [ "$total" -gt 0 ] && [ "$running" -eq "$total" ]; then
    ok "the $total Argo CD pods are Running"
else
    ko "$running/$total Argo CD pods are Running"
    echo "$pods" | grep -v Running | sed 's/^/         /'
fi

echo "=== Application ==="
app=$(kubectl get application "$APP" -n argocd --no-headers 2>/dev/null)
if [ -z "$app" ]; then
    ko "the Argo CD application '$APP' does not exist"
else
    echo "$app" | sed 's/^/         /'
    if echo "$app" | grep -q Synced; then
        ok "$APP is Synced"
    else
        ko "$APP is not Synced"
    fi
    if echo "$app" | grep -q Healthy; then
        ok "$APP is Healthy"
    else
        ko "$APP is not Healthy"
    fi
fi

echo "=== Deployed application (namespace dev) ==="
devpods=$(kubectl get pods -n dev --no-headers 2>/dev/null)
if [ -z "$devpods" ]; then
    ko "no pod in the dev namespace"
else
    echo "$devpods" | sed 's/^/         /'
    if echo "$devpods" | awk '{print $3}' | grep -q '^Running$'; then
        ok "the application pod is Running"
    else
        ko "no Running pod in dev"
    fi
fi

svc=$(kubectl get svc -n dev --no-headers 2>/dev/null)
if [ -z "$svc" ]; then
    ko "no service in the dev namespace"
else
    echo "$svc" | sed 's/^/         /'
    if echo "$svc" | awk '{print $2}' | grep -q '^NodePort$'; then
        ok "the service is a NodePort"
    else
        ko "the service is not a NodePort (the port mapping needs one)"
    fi
    if echo "$svc" | grep -q '30888'; then
        ok "the service exposes nodePort 30888"
    else
        ko "the service does not expose nodePort 30888"
    fi
fi

echo "=== HTTP access on port 8888 ==="
i=0
body=""
while [ "$i" -lt 20 ]; do
    body=$(curl -s -m 5 "$URL" 2>/dev/null)
    if [ -n "$body" ]; then
        break
    fi
    i=$((i + 1))
    sleep 3
done

if [ -z "$body" ]; then
    ko "$URL returned nothing"
else
    echo "         $body"
    if echo "$body" | grep -q '"status":"ok"'; then
        ok "the application answers with status ok"
    else
        ko "unexpected answer from the application"
    fi

    version=$(echo "$body" | grep -oE '"v[0-9]+"' | tr -d '"')
    if [ -n "$version" ]; then
        ok "the deployed version is $version"
    else
        ko "could not read the version in the answer"
    fi
fi

echo ""
echo "=== Argo CD UI ==="
echo "         kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "         https://localhost:8080  (user: admin)"
pass=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null)
if [ -n "$pass" ]; then
    echo "         password: $pass"
else
    echo "         password: (secret argocd-initial-admin-secret not found)"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "=== Part 3 OK ==="
else
    echo "=== Part 3 KO ==="
fi
exit "$FAILED"
