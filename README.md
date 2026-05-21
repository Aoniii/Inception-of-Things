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

...

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
