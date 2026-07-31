#!/bin/sh
# Usage: ./scripts/verify.sh   (run after 'setup.sh' and 'gitlab-setup.sh')
#
# Checks the bonus: everything Part 3 does, but with Argo CD watching the
# GitLab instance running locally in the cluster instead of GitHub.

APP="wil-playground"
CLUSTER="iot"
URL="http://localhost:8888/"
GITLAB_URL="https://gitlab.gitlab.local:8443"

FAILED=0

ok() { printf '  [ OK ] %s\n' "$1"; }
ko() {
    printf '  [FAIL] %s\n' "$1"
    FAILED=1
}

echo "=== Prerequisites ==="
for bin in docker kubectl k3d helm; do
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
    echo "=== Bonus KO: fix the prerequisites first ==="
    exit 1
fi

echo "=== Cluster ==="
if k3d cluster list --no-headers 2>/dev/null | grep -q "^$CLUSTER "; then
    ok "the K3d cluster '$CLUSTER' exists"
else
    ko "no K3d cluster named '$CLUSTER' (run './scripts/setup.sh')"
    echo ""
    echo "=== Bonus KO ==="
    exit 1
fi

if kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -q '^Ready$'; then
    ok "the cluster node is Ready"
else
    ko "no Ready node in the cluster"
fi

echo "=== Namespaces ==="
# the subject asks for a dedicated namespace named gitlab, on top of part 3
for ns in argocd dev gitlab; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        ok "namespace $ns exists"
    else
        ko "namespace $ns is missing"
    fi
done

echo "=== GitLab ==="
gpods=$(kubectl get pods -n gitlab --no-headers 2>/dev/null)
if [ -z "$gpods" ]; then
    ko "no pod in the gitlab namespace"
else
    # jobs legitimately end up Completed, anything else is a problem
    bad=$(echo "$gpods" | awk '{print $3}' | grep -vcE '^(Running|Completed)$')
    if [ "$bad" -eq 0 ]; then
        ok "every gitlab pod is Running or Completed"
    else
        ko "$bad gitlab pod(s) in a bad state"
        echo "$gpods" | awk '$3 !~ /^(Running|Completed)$/' | sed 's/^/         /'
    fi

    web=$(echo "$gpods" | grep 'gitlab-webservice-default')
    if echo "$web" | grep -q 'Running'; then
        ok "gitlab-webservice-default is Running"
    else
        ko "gitlab-webservice-default is not Running"
    fi

    for dep in postgresql redis-master minio; do
        if echo "$gpods" | grep "$dep" | grep -q Running; then
            ok "$dep is Running"
        else
            ko "$dep is not Running"
        fi
    done
fi

echo "=== Argo CD watches GitLab, not GitHub ==="
repo=$(kubectl get application "$APP" -n argocd -o jsonpath='{.spec.source.repoURL}' 2>/dev/null)
if [ -z "$repo" ]; then
    ko "the Argo CD application '$APP' does not exist"
else
    echo "         repoURL: $repo"
    if echo "$repo" | grep -q 'gitlab'; then
        ok "the source repository is the local GitLab"
    else
        ko "the source repository is not GitLab (the bonus needs it to be)"
    fi
    if echo "$repo" | grep -q 'github.com'; then
        ko "the application still points at GitHub"
    fi
fi

app=$(kubectl get application "$APP" -n argocd --no-headers 2>/dev/null)
if [ -n "$app" ]; then
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
if [ -n "$svc" ]; then
    echo "$svc" | sed 's/^/         /'
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
    [ -n "$body" ] && break
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
    [ -n "$version" ] && ok "the deployed version is $version" || ko "could not read the version"
fi

echo "=== GitLab UI ==="
if grep -q 'gitlab.gitlab.local' /etc/hosts 2>/dev/null; then
    ok "gitlab.gitlab.local is in /etc/hosts"
else
    ko "gitlab.gitlab.local is missing from /etc/hosts"
fi

if curl -ks -m 10 -o /dev/null -w '%{http_code}' "$GITLAB_URL/users/sign_in" 2>/dev/null | grep -q '200'; then
    ok "the GitLab UI answers on $GITLAB_URL"
else
    ko "the GitLab UI does not answer on $GITLAB_URL"
fi

echo ""
echo "=== Credentials ==="
echo "         GitLab: $GITLAB_URL  (user: root)"
gpass=$(kubectl get secret gitlab-gitlab-initial-root-password -n gitlab -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null)
[ -n "$gpass" ] && echo "         password: $gpass" || echo "         password: (secret not found)"
echo "         Argo CD: kubectl port-forward svc/argocd-server -n argocd 8080:443"
apass=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null)
[ -n "$apass" ] && echo "         password: $apass" || echo "         password: (secret not found)"

echo ""
echo "=== v1 -> v2 demo ==="
echo "         edit manifests/deployment.yaml in $GITLAB_URL/root/snourry-iot"
echo "         then force the sync instead of waiting for the 3 min poll:"
echo "         kubectl annotate application $APP -n argocd argocd.argoproj.io/refresh=hard --overwrite"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "=== Bonus OK ==="
else
    echo "=== Bonus KO ==="
fi
exit "$FAILED"
