# Inception-of-Things (IoT)

A System Administration project exploring Kubernetes through K3s, K3d, Vagrant, and Argo CD.

## Understanding K3s vs K3d

### K8s (Kubernetes)
K8s is the abbreviation for Kubernetes (K + 8 letters + s). It is the full-featured container orchestration platform created by Google. It manages clusters of nodes, scheduling pods, handling networking, storage, and scaling. It is powerful but complex to install and maintain.

### K3s
K3s is a lightweight, certified Kubernetes distribution created by Rancher Labs. It packages all Kubernetes components into a single binary (~70 MB), replaces etcd with SQLite by default, and strips out heavy cloud drivers. The name is a play on K8s: 8 minus 5 = 3, meaning it is lighter. K3s is designed for edge computing, IoT, and resource-constrained environments. In this project (Parts 1 and 2), K3s runs inside real virtual machines created by Vagrant and VirtualBox. Each VM has its own kernel and operating system.

### K3d
K3d is K3s running inside Docker containers instead of virtual machines. Instead of booting full VMs with their own kernel, K3d creates Docker containers that simulate Kubernetes nodes. This makes cluster creation almost instant (around 10 seconds) compared to several minutes with VMs. The containers share the host kernel, just like any Docker container. In this project (Part 3), K3d is used to quickly spin up a cluster for deploying applications with Argo CD.

### Key difference
K3s in VMs = each node has its own kernel and OS (stronger isolation, heavier).
K3d in Docker = each node is a container sharing the host kernel (lighter, faster, less isolation).
Both provide the same Kubernetes API, same kubectl commands, same YAML manifests.

## Part 1: K3s and Vagrant

Two virtual machines running Debian 12 with K3s installed:
- **snourryS** (192.168.56.110) — K3s server (control-plane)
- **snourrySW** (192.168.56.111) — K3s agent (worker)

### Setup

```sh
cd p1
vagrant up
```

### Verification

```sh
vagrant ssh snourryS
kubectl get nodes -o wide
ip a show eth1
```

```sh
# From another terminal
vagrant ssh snourrySW
ip a show eth1
```

Expected: both nodes in `Ready` status with correct IPs.

## Part 2: K3s and three simple applications

A single K3s server hosting three web applications, routed by hostname using Traefik Ingress:
- `app1.com` → app-one (1 replica)
- `app2.com` → app-two (3 replicas)
- Default → app-three (1 replica)

### Setup

```sh
cd p2
vagrant up
```

### Verification

```sh
vagrant ssh snourryS
kubectl get pods
kubectl get services
kubectl get deployments
kubectl get ingress
kubectl describe ingress app-ingress
```

### Testing the routing

```sh
curl -H "Host:app1.com" 192.168.56.110
curl -H "Host:app2.com" 192.168.56.110
curl 192.168.56.110
```

### Checking app2 replicas

```sh
kubectl get pods -l app=app-2
```

## Part 3: K3d and Argo CD

A K3d cluster running Argo CD for continuous deployment. Argo CD watches a public GitHub repository and automatically deploys application updates to the `dev` namespace.

### Architecture
- **Namespace `argocd`** — contains all Argo CD components (server, repo-server, controller, etc.)
- **Namespace `dev`** — contains the deployed application (`wil42/playground`)
- **GitHub repo** — stores the Kubernetes manifests that Argo CD watches
- **Docker Hub** — hosts the `wil42/playground` image (tags `v1` and `v2`)

### GitHub Repository
Part 3 requires a public GitHub repository that Argo CD watches for changes. The repository contains the Kubernetes manifests (deployment and service) for the `wil42/playground` application.

Repository: [snourry-iot](https://github.com/Aoniii/snourry-iot)

When you push a change to this repository (for example, changing the image tag from `v1` to `v2`), Argo CD automatically detects the update and redeploys the application in the `dev` namespace.

### Step 1 — Install prerequisites
```sh
cd p3
sudo ./scripts/install.sh
```
This installs Docker, kubectl, and K3d.

### Step 2 — Create the cluster and deploy
```sh
./scripts/setup.sh
```
This creates the K3d cluster, installs Argo CD, creates the namespaces, and deploys the application.

#### Verify the cluster is running
```sh
kubectl get nodes
```
Expected: one node `k3d-iot-server-0` in `Ready` status.

#### Verify namespaces
```sh
kubectl get ns
```
Expected: `argocd` and `dev` namespaces both `Active`.

#### Verify Argo CD pods
```sh
kubectl get pods -n argocd
```
Expected: all pods in `Running` status (argocd-server, argocd-repo-server, argocd-application-controller, etc.). If some pods are in `ContainerCreating`, wait 1-2 minutes and check again.

#### Verify the application pod
```sh
kubectl get pods -n dev
```
Expected: `wil-playground` pod in `Running` status. If the namespace is empty, check Argo CD sync status:
```sh
kubectl get applications -n argocd
```
If status is `OutOfSync`, check for errors:
```sh
kubectl describe application wil-playground -n argocd
```
Look at the `Events` and `Status.Operation State.Message` sections for details.

#### Verify the service
```sh
kubectl get svc -n dev
```
Expected: `wil-playground` service with type `NodePort` and nodePort `30888`.

### Step 3 — Test the application (v1)
```sh
curl http://localhost:8888/
```
Expected: `{"status":"ok", "message": "v1"}`

If you get "Empty reply from server" or "Connection refused":
1. Check that the service is `NodePort` (not `ClusterIP`): `kubectl get svc -n dev`
2. Check that the pod is running: `kubectl get pods -n dev`
3. Check the K3d port mapping: `docker ps` and look for the loadbalancer container

### Step 4 — Update to v2 (continuous deployment)
In your GitHub repository, edit `manifests/deployment.yaml` and change:
```yaml
image: wil42/playground:v1
```
to:
```yaml
image: wil42/playground:v2
```
Commit and push the change. Argo CD will automatically detect the update and synchronize (this takes up to 3 minutes).

### Cleanup
```sh
./scripts/clean.sh
```
This deletes the K3d cluster and all associated resources.

## Bonus: GitLab

Replaces GitHub with a local GitLab instance running inside the K3d cluster. Argo CD watches the GitLab repository instead of GitHub for automated continuous deployment.

### Architecture
- **Namespace `argocd`** — Argo CD components
- **Namespace `dev`** — deployed application (`wil42/playground`)
- **Namespace `gitlab`** — GitLab instance with PostgreSQL, Redis, and MinIO
- **GitLab local repo** — stores the Kubernetes manifests that Argo CD watches
- **Docker Hub** — hosts the `wil42/playground` image (tags `v1` and `v2`)

### Prerequisites
Run the install script from Part 3 if not already done:
```sh
cd bonus
sudo ./scripts/install.sh
```

### Step 1 — Create the cluster and deploy everything
```sh
./scripts/setup.sh
```
This creates the K3d cluster, installs Argo CD, deploys PostgreSQL, Redis, MinIO, and GitLab. This takes approximately 5-10 minutes.

#### Verify GitLab pods
```sh
kubectl get pods -n gitlab
```
Wait until `gitlab-webservice-default` shows `2/2 Running` and `gitlab-migrations` shows `Completed`. This can take 5-10 minutes.

### Step 2 — Configure GitLab and connect Argo CD
Once all GitLab pods are running:
```sh
./scripts/gitlab-setup.sh
```
This script:
1. Retrieves the GitLab root password
2. Adds `gitlab.gitlab.local` to `/etc/hosts`
3. Waits for GitLab to be accessible
4. Clones the manifests from GitHub and pushes them to the local GitLab
5. Makes the GitLab project public
6. Configures Argo CD to watch the GitLab repository

### Step 3 — Test the application (v1)
```sh
curl http://localhost:8888/
```
Expected: `{"status":"ok", "message": "v1"}`

If you get "Empty reply from server":
1. Check Argo CD sync status: `kubectl get applications -n argocd`
2. Check for errors: `kubectl describe application wil-playground -n argocd | grep "Message"`
3. Check pods in dev: `kubectl get pods -n dev`
4. Check service in dev: `kubectl get svc -n dev`

### Step 4 — Access GitLab UI
Open in your browser: `https://gitlab.gitlab.local:8443`

Accept the self-signed certificate. Login credentials:
- Username: `root`
- Password: retrieve with:
```sh
kubectl get secret gitlab-gitlab-initial-root-password -n gitlab -o jsonpath="{.data.password}" | base64 -d
echo
```

### Step 5 — Update to v2 (continuous deployment via GitLab)
1. Open `https://gitlab.gitlab.local:8443`
2. Navigate to the project `root/snourry-iot`
3. Edit `manifests/deployment.yaml`
4. Change `image: wil42/playground:v1` to `image: wil42/playground:v2`
5. Commit the change

Wait 1-3 minutes for Argo CD to synchronize.

#### Monitor the sync
```sh
kubectl get applications -n argocd
```
Wait until `SYNC STATUS` shows `Synced`.

#### Verify the update
```sh
curl http://localhost:8888/
```
Expected: `{"status":"ok", "message": "v2"}`

#### Check the pod was updated
```sh
kubectl get pods -n dev
```
The pod name should have changed (new pod created with the v2 image).

### Cleanup
```sh
./scripts/clean.sh
```

## Useful Vagrant commands

| Command | Description |
|---|---|
| `vagrant up` | Create and start VMs |
| `vagrant halt` | Shut down VMs |
| `vagrant destroy -f` | Delete VMs completely |
| `vagrant provision` | Re-run provisioning scripts |
| `vagrant reload` | Restart VMs |
| `vagrant ssh <name>` | SSH into a VM |
| `vagrant status` | Check VM status |
