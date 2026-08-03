# Inception-of-Things (IoT)

*[Version française](README.fr.md)*

A System Administration project about Kubernetes, built up in four steps: two
virtual machines running K3s, three web applications routed by hostname, a K3d
cluster driven by Argo CD, and finally the same continuous deployment loop
served by a GitLab instance running inside the cluster.

This README is written as a course. Each part introduces the concepts it needs,
shows how to run it, and shows two ways to prove it works: with the provided
verification script, and by hand.

---

## Table of contents

1. [Prerequisites](#1-prerequisites)
2. [Repository layout](#2-repository-layout)
3. [Part 1 — K3s and Vagrant](#3-part-1--k3s-and-vagrant)
4. [Part 2 — K3s and three applications](#4-part-2--k3s-and-three-applications)
5. [Part 3 — K3d and Argo CD](#5-part-3--k3d-and-argo-cd)
6. [Bonus — GitLab in the cluster](#6-bonus--gitlab-in-the-cluster)
7. [Troubleshooting](#7-troubleshooting)
8. [Command reference](#8-command-reference)

---

## 1. Prerequisites

### Target platform

**This project targets Ubuntu 24.04 LTS only.** Every install script checks the
distribution and refuses to run anywhere else. This is a deliberate choice: it
keeps the scripts short and predictable instead of guessing at package names
across distributions.

### The machine layout

The subject requires the whole project to run inside a virtual machine. That
gives you three levels:

```
Physical machine (your PC)
  └── Host VM — Ubuntu 24.04 LTS         ← you work here
        ├── VirtualBox → snourryS, snourrySW    (Parts 1 and 2)
        └── Docker     → k3d cluster "iot"      (Part 3 and bonus)
```

Parts 1 and 2 run VirtualBox **inside** the host VM. That is nested
virtualization, and it must be enabled on the outer hypervisor or nothing will
boot.

### Nested virtualization

Check it from inside the host VM before anything else:

```sh
grep -cE 'vmx|svm' /proc/cpuinfo
```

The answer must be greater than 0. If it is 0, enable it on the hypervisor that
runs your host VM:

| Hypervisor | How |
|---|---|
| VirtualBox | Settings → System → Processor → *Enable Nested VT-x/AMD-V*, or `VBoxManage modifyvm "<vm>" --nested-hw-virt on` |
| VMware | Settings → Processors → *Virtualize Intel VT-x/EPT or AMD-V/RVI* |
| QEMU/KVM | CPU model `host-passthrough`, and `kvm_intel nested=1` on the host |
| Hyper-V | `Set-VMProcessor -VMName "<vm>" -ExposeVirtualizationExtensions $true` |

On an Apple Silicon Mac this is not possible: there is no x86 nested
virtualization and VirtualBox does not run on ARM. Use an x86 machine.

`install-host.sh` performs this check and refuses to continue without it.

### Resources

| | RAM | Disk |
|---|---|---|
| Parts 1 to 3 | 8 GB | 40 GB |
| With the bonus | **16 GB** | **80 GB** |

The disk figure is not padding. GitLab and its dependencies pull 5 to 8 GB of
images. When free space drops below 15%, kubelet raises `DiskPressure`, taints
the node, evicts pods and refuses to schedule new ones — the cluster looks
broken for reasons that have nothing to do with your manifests.

Check before you start:

```sh
df -h /
free -h
nproc
```

### Installing the tools

Parts 1 and 2 need VirtualBox and Vagrant:

```sh
sudo ./install-host.sh
```

Part 3 needs Docker, kubectl and K3d; the bonus adds Helm. Each has its own
script, and both are idempotent:

```sh
sudo ./p3/scripts/install.sh
sudo ./bonus/scripts/install.sh
```

The Part 3 and bonus install scripts each have a matching `uninstall.sh`.

---

## 2. Repository layout

```
.
├── install-host.sh          VirtualBox + Vagrant, for Parts 1 and 2
├── p1/                      two VMs, K3s server + agent
│   ├── Vagrantfile
│   └── scripts/             server.sh, worker.sh, verify.sh
├── p2/                      one VM, three applications behind an Ingress
│   ├── Vagrantfile
│   ├── confs/               app-1.yaml, app-2.yaml, app-3.yaml, ingress.yaml
│   └── scripts/             server.sh, verify.sh
├── p3/                      K3d + Argo CD, source of truth on GitHub
│   ├── confs/               argocd-app.yaml
│   └── scripts/             install.sh, setup.sh, verify.sh, clean.sh, uninstall.sh
└── bonus/                   same, with GitLab hosted in the cluster
    ├── confs/               argocd-app.yaml, values.yaml, minio*.yaml, ...
    └── scripts/             install.sh, setup.sh, gitlab-setup.sh, verify.sh, clean.sh, uninstall.sh
```

Each part follows the same convention: executable code in `scripts/`,
Kubernetes and Helm configuration in `confs/`.

### The scripts, and what each one undoes

| Script | Role | Undone by |
|---|---|---|
| `install.sh` | installs tools on the machine | `uninstall.sh` |
| `setup.sh` | creates the cluster and deploys | `clean.sh` |
| `gitlab-setup.sh` | seeds GitLab, points Argo CD at it | `clean.sh` |
| `verify.sh` | checks, changes nothing | — |

Keeping that symmetry means you can always return to a clean state, which
matters more than it sounds when you are debugging.

---

## 3. Part 1 — K3s and Vagrant

### Concepts

**Virtual machine.** A complete emulated computer: its own kernel, its own
operating system, its own virtual disk. Strong isolation, but heavy — booting
one takes tens of seconds and costs hundreds of megabytes of RAM.

**Vagrant.** A tool that describes virtual machines in a file, the
`Vagrantfile`, instead of clicking through a GUI. You declare a base image (a
*box*), a name, a network, an amount of RAM, and provisioning scripts. Vagrant
talks to a *provider* — here VirtualBox — to make it real. The value is
reproducibility: `vagrant up` gives the same machine every time, on any
machine.

**Kubernetes.** An orchestrator. You describe the state you want ("three copies
of this container, reachable at this address") and it works continuously to
make reality match. It is often written K8s: K, eight letters, s.

**K3s.** A lightweight, CNCF-certified Kubernetes distribution from Rancher. All
components ship in a single ~70 MB binary, etcd is replaced by SQLite by
default, and in-tree cloud drivers are stripped out. The name follows the same
joke: Kubernetes is a ten-letter word written K8s, so something half its size is
a five-letter word written K3s. There is no long form.

**Server and agent.** A K3s cluster has at least one **server** node, which runs
the control plane — the API server, the scheduler, the controllers, the
datastore — and any number of **agent** nodes, which only run workloads. An
agent joins a server using its URL and a shared secret, the *node token*.

### What this part builds

Two Debian 13 machines created by Vagrant:

| Machine | IP | Role | Resources |
|---|---|---|---|
| `snourryS` | 192.168.56.110 | K3s server (control plane) | 1 vCPU, 1024 MB |
| `snourrySW` | 192.168.56.111 | K3s agent (worker) | 1 vCPU, 1024 MB |

Each machine gets two network interfaces: `eth0` for NAT (internet access, and
how Vagrant reaches it over SSH), and `eth1` on a host-only network carrying the
fixed address required by the subject.

Two details in the Vagrantfile are worth knowing:

- `v.linked_clone = true` makes VirtualBox create a differencing disk instead of
  copying the whole box image. Machine creation goes from tens of seconds to
  near-instant.
- `config.vm.box_check_update = false` skips a network round trip to Vagrant
  Cloud on every boot.

### How the node token travels

The agent needs a secret that only exists once the server has started. The
server writes it into the folder Vagrant synchronises between the host and the
guest, and the worker reads it from there:

```sh
# scripts/server.sh, once K3s is up
cp /var/lib/rancher/k3s/server/node-token /vagrant/node-token

# scripts/worker.sh, before installing
export K3S_TOKEN=$(cat /vagrant/node-token)
export K3S_URL="https://192.168.56.110:6443"
```

`worker.sh` refuses to run if the file is missing, which is what happens if you
try to bring the worker up before the server. Failing with a clear message beats
installing a broken agent in silence.

The K3s binary itself travels the same way, so it is downloaded once instead of
twice. Both artefacts are listed in `p1/.gitignore`.

### Why `--node-ip` matters

```sh
export INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644 --node-ip 192.168.56.110 ..."
```

Each machine has two interfaces. Without `--node-ip`, K3s picks the interface of
the default route — the NAT one, whose address is the same `10.0.2.15` on both
machines. The nodes would then advertise identical addresses and the pod network
would not work. Passing the host-only address explicitly is the classic fix for
this project.

`--write-kubeconfig-mode 644` makes `/etc/rancher/k3s/k3s.yaml` readable by the
`vagrant` user, so `kubectl` works without `sudo`.

### Run it

```sh
cd p1
vagrant up
```

Count a few minutes on the first run: Vagrant downloads the box, then each
machine downloads and installs K3s.

### Verify — with the script

```sh
./scripts/verify.sh
```

It checks, in order: both machines are running, hostnames match, each carries
its dedicated IP, `k3s` is active on the server and `k3s-agent` on the worker,
`kubectl` is installed, and both nodes appear `Ready` with the right addresses.

```
=== Virtual machines ===
  [ OK ] snourryS is running
  [ OK ] snourrySW is running
=== Dedicated IPs ===
  [ OK ] snourryS has 192.168.56.110 on interface eth1
...
=== Part 1 OK ===
```

### Verify — by hand

You should be able to do this without the script. Connect to the server:

```sh
vagrant ssh snourryS
```

Check the identity and the address of the machine:

```sh
hostname
ip -br -4 addr
```

`ip -br` prints one line per interface; you are looking for `192.168.56.110/24`.
The interface is `eth1` on this box, but modern distributions may name it
`enp0s8` — check what you actually have rather than assuming.

Check that K3s runs in the right mode:

```sh
systemctl status k3s
```

Then look at the cluster:

```sh
kubectl get nodes -o wide
```

```
NAME        STATUS   ROLES                  AGE   VERSION        INTERNAL-IP
snourrys    Ready    control-plane,master   5m    v1.36.2+k3s1   192.168.56.110
snourrysw   Ready    <none>                 3m    v1.36.2+k3s1   192.168.56.111
```

Three things to point out here:

- The node names are **lowercase**, while the hostnames keep their capital
  letter. Kubelet lowercases the hostname because a node name must be a valid
  DNS name. This is normal.
- The worker shows `<none>` under ROLES. K3s does not label its agents; only the
  control plane gets a role label. Also normal.
- INTERNAL-IP shows the host-only addresses, which proves `--node-ip` did its
  job.

On the worker, only the network is worth checking:

```sh
vagrant ssh snourrySW -c "ip -br -4 addr"
```

`kubectl` will not work there — an agent has no kubeconfig, since it does not
run the API server.

### Clean up

```sh
vagrant destroy -f
```

Do this before moving to Part 2. Both parts declare a VirtualBox machine named
`snourryS`, and VirtualBox refuses two machines with the same name.


### Sources

- [Vagrant — VirtualBox provider configuration](https://developer.hashicorp.com/vagrant/docs/providers/virtualbox/configuration) — `linked_clone`, `memory`, `cpus`
- [Vagrant — private networks](https://developer.hashicorp.com/vagrant/docs/networking/private_network) — the fixed host-only address
- [K3s — server configuration reference](https://docs.k3s.io/cli/server) — `--node-ip`, `--write-kubeconfig-mode`, `--disable`
- [K3s — agent configuration reference](https://docs.k3s.io/cli/agent) — `K3S_URL`, `K3S_TOKEN`
- [K3s — FAQ](https://docs.k3s.io/faq) — where the name comes from
- [Kubernetes — object names](https://kubernetes.io/docs/concepts/overview/working-with-objects/names/) — why node names are lowercase DNS names
- [VirtualBox manual — host-only networking](https://www.virtualbox.org/manual/ch06.html) — the 192.168.56.0/21 restriction

---

## 4. Part 2 — K3s and three applications

### Concepts

**Pod.** The smallest deployable unit in Kubernetes: one or more containers
sharing a network namespace and storage. You rarely create pods directly.

**Deployment.** Declares *how many* copies of a pod you want and *which* image
they run. A controller keeps that number satisfied: kill a pod and a replacement
appears. This is what the subject means by replicas.

**Service.** A pod's IP changes every time it is recreated, so you never address
one directly. A Service gives a stable name and virtual IP, and load-balances
across the pods matching its selector. Here each Service listens on port 80 and
forwards to port 8080 in the container.

**Ingress.** A Service is reachable inside the cluster. An Ingress exposes HTTP
routes from outside, and can route on the `Host` header — which is exactly what
this part requires. An Ingress is only a description; something has to enforce
it.

**Ingress controller.** The component that reads Ingress objects and configures
a real reverse proxy. K3s ships **Traefik** and enables it by default. Part 1
disabled it (nothing needed it, and it saves memory on a 1 GB machine); Part 2
keeps it, because the whole part depends on it.

### What this part builds

One machine, `snourryS` at 192.168.56.110, 2 vCPU and 2048 MB, hosting three
applications routed by hostname:

| Host header | Application | Replicas |
|---|---|---|
| `app1.com` | `app-1` | 1 |
| `app2.com` | `app-2` | **3** |
| anything else | `app-3` | 1 |

All three run `paulbouwer/hello-kubernetes:1.10.1`, which serves a page showing
the value of its `MESSAGE` environment variable — a simple way to tell which
application answered.

### How the default route works

`confs/ingress.yaml` declares three rules. The first two carry a `host:`; the
third does not:

```yaml
    - http:                     # no host: matches anything
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app-3
```

A rule without a host matches any hostname. It does not shadow the other two
because Traefik ranks rules by specificity: `Host(app1.com) && PathPrefix(/)` is
more specific than `PathPrefix(/)` alone, so it wins when the header matches.

The Ingress also sets `ingressClassName: traefik`, which states explicitly which
controller should handle it rather than relying on the default.

### Run it

```sh
cd p2
vagrant up
```

`scripts/server.sh` installs K3s, waits for the node to be `Ready`, then applies
everything in `confs/`:

```sh
while ! kubectl wait --for=condition=Ready node --all --timeout=10s >/dev/null 2>&1; do
    sleep 1
done
kubectl apply -f /vagrant/confs/
```

The wait uses `kubectl wait` rather than grepping for `Ready` — because
`NotReady` contains the string `Ready`, and a naive grep exits immediately.

### Verify — with the script

```sh
./scripts/verify.sh
```

Beyond the machine and K3s checks, it waits for Traefik and the deployments to
settle, then performs the real test: three HTTP requests with different `Host`
headers, from the host VM, exactly as an evaluator would.

Allow a few minutes on a fresh `vagrant up`: Traefik is deployed by a Helm job
and the application image has to be pulled.

### Verify — by hand

Look at the objects first:

```sh
vagrant ssh snourryS
kubectl get deployments
kubectl get services
kubectl get ingress
```

```
NAME    READY   UP-TO-DATE   AVAILABLE
app-1   1/1     1            1
app-2   3/3     3            3
app-3   1/1     1            1
```

The `READY` column of `app-2` is the replica requirement: three ready out of
three requested. To see them individually:

```sh
kubectl get pods -l app=app-2
```

`-l` filters by label. Three pods, three different names, all `Running`.

Look at the Ingress in detail — the subject asks you to show it during the
defense:

```sh
kubectl describe ingress app-ingress
```

The `Rules` section lists the three routes and the Service each one points to.

Then the test that matters, **from the host VM**, not from inside:

```sh
curl -H "Host:app1.com" 192.168.56.110
curl -H "Host:app2.com" 192.168.56.110
curl 192.168.56.110
```

The three responses must show `app-1`, `app-2` and `app-3` respectively. The
last one carries no `Host` header, so it lands on the default rule.

To watch the load balancing across the three replicas, repeat the second request
a few times and look at the pod name displayed on the page — it changes.

### Clean up

```sh
vagrant destroy -f
```


### Sources

- [Kubernetes — Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) — replicas and selectors
- [Kubernetes — Services](https://kubernetes.io/docs/concepts/services-networking/service/) — stable address, `targetPort`
- [Kubernetes — Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/) — rules, `pathType`, `ingressClassName`, and the host-less rule
- [Traefik — routers and priority](https://doc.traefik.io/traefik/routing/routers/) — why the default rule does not shadow the others
- [K3s — bundled networking services](https://docs.k3s.io/networking/networking-services) — Traefik enabled by default
- [paulbouwer/hello-kubernetes](https://github.com/paulbouwer/hello-kubernetes) — the `MESSAGE` variable

---

## 5. Part 3 — K3d and Argo CD

### Concepts

**Container.** A process isolated by the kernel, not a whole machine. It shares
the host kernel, starts in milliseconds and costs a few megabytes. Weaker
isolation than a VM, far lighter.

**K3d.** K3s running inside Docker containers instead of virtual machines. Each
"node" is a container. Creating a cluster takes about ten seconds instead of
several minutes. Same Kubernetes API, same `kubectl`, same manifests — only the
substrate changes.

| | K3s in VMs (Parts 1–2) | K3d in Docker (Part 3+) |
|---|---|---|
| Node | full VM, own kernel | container, shared kernel |
| Boot | minutes | seconds |
| Isolation | strong | weaker |
| API | identical | identical |

**NodePort.** A Service type that opens the same port on every node, in the
30000–32767 range. Here the application's Service uses `nodePort: 30888`.

**The K3d port mapping.** `--port "8888:30888@loadbalancer"` tells K3d to
publish port 8888 of your machine onto port 30888 of the cluster's load
balancer. That is what makes `curl http://localhost:8888/` reach the pod. The
subject requires port 8888; the NodePort is an implementation detail that has to
match on both sides.

**GitOps.** A deployment model where a Git repository is the single source of
truth. You do not run `kubectl apply` by hand; you commit. An agent inside the
cluster watches the repository and makes the cluster match it. Two consequences:
the state is auditable through Git history, and any manual drift gets corrected.

**Argo CD.** The GitOps agent used here. Its `Application` object says: watch
*this* repository, at *this* path, and apply it to *this* namespace.

```yaml
spec:
  source:
    repoURL: https://github.com/Aoniii/snourry-iot
    targetRevision: HEAD
    path: manifests
  destination:
    namespace: dev
  syncPolicy:
    automated:
      selfHeal: true      # undo manual changes
      prune: true         # delete what disappeared from Git
```

`selfHeal` is the interesting one: delete the Deployment by hand and Argo CD
puts it back, because Git still describes it.

### What this part builds

A K3d cluster named `iot` with two namespaces, as the subject requires:

- **`argocd`** — the Argo CD components
- **`dev`** — the deployed application, `wil42/playground`, which answers on
  port 8888 and exists in two tags, `v1` and `v2`

The manifests live in a separate public GitHub repository,
[snourry-iot](https://github.com/Aoniii/snourry-iot), whose name contains a team
member's login as required.

### Run it

```sh
cd p3
sudo ./scripts/install.sh     # Docker, kubectl, K3d
./scripts/setup.sh            # cluster, namespaces, Argo CD, Application
```

`setup.sh` is replayable: it deletes an existing `iot` cluster before creating a
new one, and creates namespaces only when they are missing.

### Verify — with the script

```sh
./scripts/verify.sh
```

It checks the tools, the cluster, both namespaces, that every Argo CD pod is
running, that the Application is `Synced` and `Healthy`, that the pod in `dev`
is running behind a NodePort service on 30888, and finally that
`http://localhost:8888/` answers. It prints the deployed version and the Argo CD
credentials.

### Verify — by hand

```sh
kubectl get nodes                    # one node, k3d-iot-server-0, Ready
kubectl get ns                       # argocd and dev, both Active
kubectl get pods -n argocd           # every Argo CD component Running
kubectl get applications -n argocd   # wil-playground, Synced, Healthy
kubectl get pods -n dev              # wil-playground-xxxxx, Running
kubectl get svc -n dev               # NodePort, 8888:30888/TCP
```

Then the test from the subject:

```sh
curl http://localhost:8888/
```

```json
{"status":"ok", "message": "v1"}
```

If the Application is `OutOfSync` or the `dev` namespace is empty, the details
are in:

```sh
kubectl describe application wil-playground -n argocd
```

Look at `Events` and at `Status.Operation State.Message`.

### The Argo CD web interface

The subject shows screenshots of it, so be ready to display it. Nothing exposes
it by default; forward a port:

```sh
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Then open `https://localhost:8080` and accept the self-signed certificate.
Username `admin`, and the password:

```sh
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

`verify.sh` prints this command and the password for you.

### The GitOps loop: switching from v1 to v2

This is the demonstration the subject requires — proving that a change committed
to Git reaches the cluster on its own.

**Step 1 — change the version in the repository.**

Working on a clone of `snourry-iot`:

```sh
git clone https://github.com/Aoniii/snourry-iot.git
cd snourry-iot

sed -i 's|wil42/playground:v1|wil42/playground:v2|' manifests/deployment.yaml
git diff                       # show the change before committing
git commit -am "switch to v2"
git push
```

`git diff` before committing is worth doing in front of an evaluator: it shows
exactly one line changing, which makes the causality obvious.

**Step 2 — understand the delay.**

Argo CD does not receive a notification when you push. It runs a *reconciliation
loop*: every three minutes by default, it re-reads the repository, compares it
with the cluster, and applies the difference. So nothing happens for up to three
minutes — which is a long silence in front of an evaluator.

**Step 3 — force the refresh instead of waiting.**

```sh
kubectl annotate application wil-playground -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

This annotation asks Argo CD to re-read the repository immediately. `hard`
bypasses its manifest cache, unlike `normal` which may reuse it — with a single
changed tag, `hard` is the reliable choice.

If you prefer changing the interval permanently rather than triggering by hand:

```sh
kubectl -n argocd patch configmap argocd-cm --type merge \
  -p '{"data":{"timeout.reconciliation":"30s"}}'
kubectl -n argocd rollout restart deployment argocd-repo-server
```

Useful while developing, but leave the default for the defense: explaining *why*
there is a delay is better than hiding it.

**Step 4 — show the change.**

Watch the sync status:

```sh
kubectl get applications -n argocd -w
```

It goes `Synced` → `OutOfSync` → `Synced`. Press Ctrl+C to stop watching.

Watch the pod being replaced:

```sh
kubectl get pods -n dev -w
```

A new pod appears, becomes `Running`, and the old one disappears. The name
changes, which proves it is a new pod and not a restart.

Then the proof itself:

```sh
curl http://localhost:8888/
```

```json
{"status":"ok", "message": "v2"}
```

Or run `./scripts/verify.sh`, whose last line reports the deployed version.

**Step 5 — leave the demo replayable.** Put the manifest back to `v1` and push,
so you can run through it again.

### Bonus demonstration: self-healing

Worth showing if you have time, because it makes GitOps click:

```sh
kubectl delete deployment wil-playground -n dev
kubectl get pods -n dev -w
```

The Deployment comes back on its own. You did not restore it — Argo CD noticed
the cluster no longer matched Git and corrected it. That is `selfHeal: true`.

### Clean up

```sh
./scripts/clean.sh        # deletes the cluster, keeps the tools
sudo ./scripts/uninstall.sh   # removes Docker, kubectl and K3d
```


### Sources

- [K3d — exposing services](https://k3d.io/stable/usage/exposing_services/) — the `--port ...@loadbalancer` mapping
- [Kubernetes — Service type NodePort](https://kubernetes.io/docs/concepts/services-networking/service/#type-nodeport) — the 30000–32767 range
- [Argo CD — declarative setup](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/) — the `Application` object
- [Argo CD — automated sync policy](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/) — `selfHeal` and `prune`
- [Argo CD — FAQ](https://argo-cd.readthedocs.io/en/stable/faq/) — how often the repository is polled, and how to force a refresh
- [Argo CD — getting started](https://argo-cd.readthedocs.io/en/stable/getting_started/) — `argocd-initial-admin-secret`

---

## 6. Bonus — GitLab in the cluster

### Goal

Replace GitHub with a GitLab instance **running inside the cluster**, and have
Argo CD watch it. Everything Part 3 does must still work, with the source of
truth hosted locally.

### Additional concepts

**Helm.** A package manager for Kubernetes. A *chart* is a parameterised bundle
of manifests; a `values.yaml` file overrides its defaults; installing a chart
creates a *release* you can upgrade or roll back. GitLab in Kubernetes is dozens
of objects — deploying it by hand is not reasonable, hence Helm.

**Why external PostgreSQL, Redis and MinIO.** The GitLab chart can deploy its
own dependencies, but here they are installed separately for control over
versions and resources. GitLab needs a database (PostgreSQL), a cache and job
queue (Redis), and S3-compatible object storage for artifacts, uploads and the
registry (MinIO).

**Pinned chart versions.** In `setup.sh`:

```sh
POSTGRESQL_VERSION="18.8.4"
REDIS_VERSION="27.0.18"
GITLAB_VERSION="10.0.0"
```

Without `--version`, Helm installs whatever is newest *at that moment*. Two runs
a month apart give two different versions. Since Bitnami restricted free access
to its images in August 2025, an unpinned chart can suddenly reference images
you can no longer pull. Pinning is what makes the bonus reproducible on defense
day.

### What this part builds

The same cluster as Part 3, plus a third namespace:

- **`gitlab`** — GitLab, PostgreSQL, Redis, MinIO
- two port mappings: `8888:30888` for the application, `8443:30443` for the
  GitLab web interface
- `--servers-memory 12g`, a cap on the cluster container so it cannot starve the
  host VM

Argo CD's `Application` now points at the in-cluster address:

```yaml
repoURL: http://gitlab-webservice-default.gitlab.svc.cluster.local:8181/root/snourry-iot.git
```

That is a Kubernetes internal DNS name: `<service>.<namespace>.svc.cluster.local`.
Argo CD reaches GitLab without leaving the cluster.

### Run it

```sh
cd bonus
sudo ./scripts/install.sh     # + Helm
./scripts/setup.sh            # cluster, Argo CD, PostgreSQL, Redis, MinIO, GitLab
```

Allow 10 to 15 minutes. Wait until GitLab is up:

```sh
kubectl get pods -n gitlab
```

Four pods matter before continuing:

```
gitlab-migrations-...       0/1   Completed    database schema created
gitlab-webservice-default   2/2   Running      API and git-over-HTTP
gitlab-toolbox              1/1   Running      used for the rails console
gitlab-gitaly-0             1/1   Running      repository storage
```

`Completed` is normal for `gitlab-migrations` and `gitlab-issuer`: those are
Jobs, they are supposed to finish. Early restarts on `webservice` and `sidekiq`
are also normal — they start before the migrations finish, fail, and settle.

Then:

```sh
./scripts/gitlab-setup.sh
```

This script gets the root password, adds `gitlab.gitlab.local` to `/etc/hosts`,
waits for the interface, clones the manifests from GitHub and pushes them into
the local GitLab, makes the project public so Argo CD can clone it anonymously,
and finally applies the `Application`.

Two details are worth knowing:

- GitLab creates the project automatically on the first push — that is the
  *push-to-create* feature.
- The project is looked up by path, not by ID:
  `Project.find_by_full_path('root/snourry-iot')`. Assuming the ID is 1 works
  until it does not, and then you silently publish the wrong project.

### Verify — with the script

```sh
./scripts/verify.sh
```

Same checks as Part 3, plus the three namespaces, the GitLab pods, the web
interface, and the check specific to this part:

```
=== Argo CD watches GitLab, not GitHub ===
         repoURL: http://gitlab-webservice-default.gitlab.svc.cluster.local:8181/root/snourry-iot.git
  [ OK ] the source repository is the local GitLab
```

It fails explicitly if the URL still contains `github.com` — which is precisely
what separates the bonus from Part 3.

### Verify — by hand

```sh
kubectl get ns                       # argocd, dev and gitlab
kubectl get pods -n gitlab           # Running or Completed
kubectl get application wil-playground -n argocd -o jsonpath='{.spec.source.repoURL}'
kubectl get pods -n dev
curl http://localhost:8888/
```

The `jsonpath` query is the one to show: it prints the source repository and
nothing else, so the point is unambiguous.

Then open the GitLab interface at `https://gitlab.gitlab.local:8443`, accept the
self-signed certificate, and log in as `root` with:

```sh
kubectl get secret gitlab-gitlab-initial-root-password -n gitlab \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

### The GitOps loop, through GitLab

Same principle as Part 3, but the source of truth is now local.

**Through the web interface**, which is the most visual:

1. Open `https://gitlab.gitlab.local:8443` and log in as `root`
2. Go to the project `root/snourry-iot`
3. Open `manifests/deployment.yaml` and click *Edit*
4. Change `wil42/playground:v1` to `v2`
5. Commit — GitLab shows the diff before you confirm

**Through the command line**, if you prefer:

```sh
git clone https://gitlab.gitlab.local:8443/root/snourry-iot.git
cd snourry-iot
sed -i 's|playground:v1|playground:v2|' manifests/deployment.yaml
git commit -am "v2"
GIT_SSL_NO_VERIFY=true git push
```

`GIT_SSL_NO_VERIFY` is needed because the GitLab certificate is self-signed —
acceptable for a local lab, never in production.

**Then, exactly as in Part 3**, force the refresh instead of waiting three
minutes:

```sh
kubectl annotate application wil-playground -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

kubectl get pods -n dev -w
curl http://localhost:8888/
```

```json
{"status":"ok", "message": "v2"}
```

The point to make out loud: **nothing outside the machine was involved**. The
repository, the GitOps agent and the application all run in the same cluster.

### Clean up

```sh
./scripts/clean.sh
```

Unlike Part 3, this one also removes the `/etc/hosts` entry and the GitLab Helm
repository — both are host-level state that surviving the cluster would leave
behind.


### Sources

- [Helm — charts](https://helm.sh/docs/topics/charts/) and [values files](https://helm.sh/docs/chart_template_guide/values_files/)
- [Helm — `helm upgrade`](https://helm.sh/docs/helm/helm_upgrade/) — `--install`, `--wait`, `--version`
- [GitLab chart — documentation](https://docs.gitlab.com/charts/) and [global settings](https://docs.gitlab.com/charts/charts/globals.html)
- [Bitnami — restricted access to free images, August 2025](https://github.com/bitnami/containers/issues/83267) — the announcement Helm itself points to during the install
- [MinIO — Kubernetes documentation](https://min.io/docs/minio/kubernetes/upstream/) and [`mc mb`](https://min.io/docs/minio/linux/reference/minio-mc/mc-mb.html)
- [Kubernetes — DNS for services](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/) — the `<service>.<namespace>.svc.cluster.local` form

---

## 7. Troubleshooting

Every entry below was actually hit while building this project.

### `vagrant up` fails: a VM with that name already exists

The `.vagrant` folder was deleted or moved without a `vagrant destroy`, so
Vagrant lost track of a machine VirtualBox still has.

```sh
VBoxManage list vms
VBoxManage controlvm snourryS poweroff
VBoxManage unregistervm snourryS --delete
rm -rf p1/.vagrant p2/.vagrant
```

If it stays locked, kill the leftover process (`pkill -f snourryS`), then
`VBoxSVC` as a last resort — it restarts on its own.

### The private key must be owned by the user running Vagrant

You are running Vagrant from a VirtualBox shared folder. The `vboxsf` filesystem
forces ownership and permissions from its mount options, so the generated SSH key
can never satisfy SSH's requirements.

Copy the project to the VM's own disk. You can keep editing through the shared
folder and sync before each test:

```sh
rsync -a --delete --exclude '.vagrant' /media/sf_project/ ~/project/
```

### Pods stuck in Pending, others showing Completed

Almost always disk pressure. Below 15% free, kubelet taints the node and nothing
can be scheduled.

```sh
df -h /
kubectl describe node | grep -A15 Conditions
```

Free space — the Vagrant VMs of the other parts are usually the biggest win —
then recreate the cluster. The taint clears on its own once space is back.

### `kubectl wait` fails with NotFound or "no matching resources found"

`kubectl wait` does not wait for an object to be *created*; it fails immediately
if it does not exist. Right after a `helm install` or a `kubectl apply`, the
Deployment exists but its pods do not yet.

Wait on an object created synchronously, not on a pod:

```sh
kubectl rollout status deployment/minio -n gitlab --timeout=300s
helm upgrade --install ... --wait --timeout 10m
```

### vboxdrv is not loaded

The DKMS module failed to build, or Secure Boot is refusing an unsigned module.

```sh
dkms status
mokutil --sb-state
sudo /sbin/vboxconfig
```

`install-host.sh` checks this before finishing, so it will not report success on
a broken installation.

### Everything reports failed right after starting a part

The verification scripts wait for what needs waiting, but a fresh cluster can
still take several minutes to pull images. Compare the `AGE` column between the
sections of the output: if the first checks ran at 2 minutes and the last at 7,
the run simply started too early. Run it again.

### Argo CD stays OutOfSync

```sh
kubectl describe application wil-playground -n argocd
```

The `Message` field usually names the cause: repository unreachable, private
project, wrong path.


### Sources

- [Kubernetes — node-pressure eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/) — the default thresholds, including `imagefs.available<15%`
- [Kubernetes — `kubectl wait`](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_wait/) — why it fails instead of waiting when the object is missing
- [VirtualBox manual — shared folders](https://www.virtualbox.org/manual/ch04.html) — the `vboxsf` ownership and permission limits

---

## 8. Command reference

### Vagrant

| Command | Effect |
|---|---|
| `vagrant up` | create and start the machines |
| `vagrant ssh <name>` | connect |
| `vagrant ssh <name> -c "cmd"` | run one command and exit |
| `vagrant provision` | replay the provisioning scripts |
| `vagrant reload` | restart |
| `vagrant halt` | shut down |
| `vagrant destroy -f` | delete completely |
| `vagrant status` | current state |
| `vagrant snapshot save <name>` | snapshot |
| `vagrant snapshot restore <name>` | restore in seconds |

### kubectl

| Command | Effect |
|---|---|
| `kubectl get nodes -o wide` | nodes with their addresses |
| `kubectl get pods -A` | every pod in every namespace |
| `kubectl get pods -n <ns> -w` | watch live |
| `kubectl get pods -l app=app-2` | filter by label |
| `kubectl describe <kind> <name>` | detail and events |
| `kubectl logs <pod> -n <ns>` | logs |
| `kubectl apply -f <file\|dir>` | apply manifests |
| `kubectl rollout status deployment/<name>` | wait for a rollout |
| `kubectl port-forward svc/<name> -n <ns> 8080:443` | expose locally |

### K3d and Argo CD

| Command | Effect |
|---|---|
| `k3d cluster list` | list clusters |
| `k3d cluster delete iot` | delete the cluster |
| `kubectl get applications -n argocd` | sync and health status |
| `kubectl annotate application <app> -n argocd argocd.argoproj.io/refresh=hard --overwrite` | force an immediate refresh |

### Helm

| Command | Effect |
|---|---|
| `helm list -n gitlab` | installed releases and chart versions |
| `helm get values <release> -n <ns>` | values actually applied |
| `helm show chart <chart>` | chart metadata, including its version |
| `helm upgrade --install ... --wait` | install or upgrade, waiting for readiness |

