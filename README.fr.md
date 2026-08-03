# Inception-of-Things (IoT)

*[English version](README.md)*

Un projet d'administration système autour de Kubernetes, construit en quatre
étapes : deux machines virtuelles sous K3s, trois applications web routées par
nom d'hôte, un cluster K3d piloté par Argo CD, et enfin la même boucle de
déploiement continu alimentée par une instance GitLab hébergée dans le cluster.

Ce README est écrit comme un cours. Chaque partie introduit les notions dont
elle a besoin, montre comment la lancer, et montre deux façons de prouver
qu'elle fonctionne : avec le script de vérification fourni, et à la main.

---

## Sommaire

1. [Prérequis](#1-prérequis)
2. [Organisation du dépôt](#2-organisation-du-dépôt)
3. [Partie 1 — K3s et Vagrant](#3-partie-1--k3s-et-vagrant)
4. [Partie 2 — K3s et trois applications](#4-partie-2--k3s-et-trois-applications)
5. [Partie 3 — K3d et Argo CD](#5-partie-3--k3d-et-argo-cd)
6. [Bonus — GitLab dans le cluster](#6-bonus--gitlab-dans-le-cluster)
7. [Dépannage](#7-dépannage)
8. [Aide-mémoire](#8-aide-mémoire)

---

## 1. Prérequis

### Plateforme cible

**Ce projet cible uniquement Ubuntu 24.04 LTS.** Chaque script d'installation
vérifie la distribution et refuse de s'exécuter ailleurs. C'est un choix
délibéré : les scripts restent courts et prévisibles au lieu de deviner des noms
de paquets d'une distribution à l'autre.

### L'empilement des machines

Le sujet impose que tout le projet tourne dans une machine virtuelle. Cela donne
trois niveaux :

```
Machine physique (votre PC)
  └── VM hôte — Ubuntu 24.04 LTS          ← vous travaillez ici
        ├── VirtualBox → snourryS, snourrySW    (parties 1 et 2)
        └── Docker     → cluster k3d « iot »    (partie 3 et bonus)
```

Les parties 1 et 2 lancent VirtualBox **à l'intérieur** de la VM hôte. C'est de
la virtualisation imbriquée, et elle doit être activée sur l'hyperviseur externe
sinon rien ne démarrera.

### Virtualisation imbriquée

À vérifier depuis la VM hôte, avant toute chose :

```sh
grep -cE 'vmx|svm' /proc/cpuinfo
```

Le résultat doit être supérieur à 0. S'il vaut 0, activez-la sur l'hyperviseur
qui fait tourner votre VM hôte :

| Hyperviseur | Comment |
|---|---|
| VirtualBox | Configuration → Système → Processeur → *Activer VT-x/AMD-V imbriqué*, ou `VBoxManage modifyvm "<vm>" --nested-hw-virt on` |
| VMware | Paramètres → Processeurs → *Virtualiser Intel VT-x/EPT ou AMD-V/RVI* |
| QEMU/KVM | modèle de CPU `host-passthrough`, et `kvm_intel nested=1` côté hôte |
| Hyper-V | `Set-VMProcessor -VMName "<vm>" -ExposeVirtualizationExtensions $true` |

Sur un Mac Apple Silicon, c'est impossible : il n'y a pas de virtualisation
imbriquée x86 et VirtualBox ne tourne pas sur ARM. Utilisez une machine x86.

`install-host.sh` effectue ce contrôle et refuse de continuer sans lui.

### Ressources

| | RAM | Disque |
|---|---|---|
| Parties 1 à 3 | 8 Go | 40 Go |
| Avec le bonus | **16 Go** | **80 Go** |

Le chiffre du disque n'est pas une marge de confort. GitLab et ses dépendances
téléchargent 5 à 8 Go d'images. Quand l'espace libre passe sous 15 %, kubelet
déclenche `DiskPressure`, pose un *taint* sur le nœud, évince les pods et refuse
d'en planifier de nouveaux — le cluster paraît cassé pour des raisons qui n'ont
rien à voir avec vos manifests.

À vérifier avant de commencer :

```sh
df -h /
free -h
nproc
```

### Installer les outils

Les parties 1 et 2 ont besoin de VirtualBox et Vagrant :

```sh
sudo ./install-host.sh
```

La partie 3 a besoin de Docker, kubectl et K3d ; le bonus ajoute Helm. Chacune a
son script, et les deux sont idempotents :

```sh
sudo ./p3/scripts/install.sh
sudo ./bonus/scripts/install.sh
```

Les scripts d'installation de la partie 3 et du bonus ont chacun leur `uninstall.sh`.

---

## 2. Organisation du dépôt

```
.
├── install-host.sh          VirtualBox + Vagrant, pour les parties 1 et 2
├── p1/                      deux VMs, K3s serveur + agent
│   ├── Vagrantfile
│   └── scripts/             server.sh, worker.sh, verify.sh
├── p2/                      une VM, trois applications derrière un Ingress
│   ├── Vagrantfile
│   ├── confs/               app-1.yaml, app-2.yaml, app-3.yaml, ingress.yaml
│   └── scripts/             server.sh, verify.sh
├── p3/                      K3d + Argo CD, source de vérité sur GitHub
│   ├── confs/               argocd-app.yaml
│   └── scripts/             install.sh, setup.sh, verify.sh, clean.sh, uninstall.sh
└── bonus/                   idem, avec GitLab hébergé dans le cluster
    ├── confs/               argocd-app.yaml, values.yaml, minio*.yaml, ...
    └── scripts/             install.sh, setup.sh, gitlab-setup.sh, verify.sh, clean.sh, uninstall.sh
```

Chaque partie suit la même convention : le code exécutable dans `scripts/`, la
configuration Kubernetes et Helm dans `confs/`.

### Les scripts, et ce que chacun défait

| Script | Rôle | Défait par |
|---|---|---|
| `install.sh` | installe les outils sur la machine | `uninstall.sh` |
| `setup.sh` | crée le cluster et déploie | `clean.sh` |
| `gitlab-setup.sh` | alimente GitLab, y branche Argo CD | `clean.sh` |
| `verify.sh` | contrôle, ne modifie rien | — |

Cette symétrie permet de toujours revenir à un état propre, ce qui compte plus
qu'il n'y paraît quand on débogue.

---

## 3. Partie 1 — K3s et Vagrant

### Notions

**Machine virtuelle.** Un ordinateur émulé complet : son propre noyau, son
propre système, son propre disque virtuel. Isolation forte, mais lourde —
démarrer prend des dizaines de secondes et coûte des centaines de méga-octets de
RAM.

**Vagrant.** Un outil qui décrit des machines virtuelles dans un fichier, le
`Vagrantfile`, au lieu de cliquer dans une interface. On y déclare une image de
base (une *box*), un nom, un réseau, une quantité de RAM et des scripts de
provisionnement. Vagrant s'adresse ensuite à un *provider* — ici VirtualBox —
pour les créer réellement. L'intérêt est la reproductibilité : `vagrant up`
produit la même machine à chaque fois, sur n'importe quelle machine.

**Kubernetes.** Un orchestrateur. On décrit l'état souhaité (« trois copies de
ce conteneur, joignables à cette adresse ») et il travaille en continu pour que
la réalité y corresponde. On l'écrit souvent K8s : K, huit lettres, s.

**K3s.** Une distribution Kubernetes légère et certifiée CNCF, créée par
Rancher. Tous les composants tiennent dans un binaire d'environ 70 Mo, etcd est
remplacé par SQLite par défaut, et les pilotes cloud intégrés sont retirés. Le
nom prolonge la même plaisanterie : Kubernetes est un mot de dix lettres écrit
K8s, donc quelque chose de moitié plus petit est un mot de cinq lettres écrit
K3s. Il n'y a pas de forme longue.

**Serveur et agent.** Un cluster K3s comporte au moins un nœud **serveur**, qui
fait tourner le plan de contrôle — serveur d'API, ordonnanceur, contrôleurs,
base de données — et un nombre quelconque de nœuds **agents**, qui n'exécutent
que des charges de travail. Un agent rejoint un serveur grâce à son URL et à un
secret partagé, le *node token*.

### Ce que construit cette partie

Deux machines Debian 13 créées par Vagrant :

| Machine | IP | Rôle | Ressources |
|---|---|---|---|
| `snourryS` | 192.168.56.110 | serveur K3s (plan de contrôle) | 1 vCPU, 1024 Mo |
| `snourrySW` | 192.168.56.111 | agent K3s (worker) | 1 vCPU, 1024 Mo |

Chaque machine reçoit deux interfaces réseau : `eth0` en NAT (accès Internet, et
chemin par lequel Vagrant s'y connecte en SSH), et `eth1` sur un réseau
host-only portant l'adresse fixe exigée par le sujet.

Deux détails du Vagrantfile méritent d'être connus :

- `v.linked_clone = true` demande à VirtualBox de créer un disque différentiel
  au lieu de copier toute l'image de la box. La création passe de dizaines de
  secondes à quasi instantanée.
- `config.vm.box_check_update = false` évite un aller-retour réseau vers Vagrant
  Cloud à chaque démarrage.

### Comment le node token circule

L'agent a besoin d'un secret qui n'existe qu'une fois le serveur démarré. Le
serveur l'écrit dans le dossier que Vagrant synchronise entre l'hôte et
l'invité, et le worker l'y lit :

```sh
# scripts/server.sh, une fois K3s démarré
cp /var/lib/rancher/k3s/server/node-token /vagrant/node-token

# scripts/worker.sh, avant l'installation
export K3S_TOKEN=$(cat /vagrant/node-token)
export K3S_URL="https://192.168.56.110:6443"
```

`worker.sh` refuse de s'exécuter si le fichier manque, ce qui arrive quand on
tente de démarrer le worker avant le serveur. Échouer avec un message clair vaut
mieux qu'installer un agent cassé en silence.

Le binaire K3s emprunte le même chemin, il n'est donc téléchargé qu'une fois au
lieu de deux. Les deux artefacts figurent dans `p1/.gitignore`.

### Pourquoi `--node-ip` est indispensable

```sh
export INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644 --node-ip 192.168.56.110 ..."
```

Chaque machine a deux interfaces. Sans `--node-ip`, K3s retient celle de la
route par défaut — la NAT, dont l'adresse est le même `10.0.2.15` sur les deux
machines. Les nœuds annonceraient alors des adresses identiques et le réseau des
pods ne fonctionnerait pas. Passer explicitement l'adresse host-only est le
correctif classique de ce projet.

`--write-kubeconfig-mode 644` rend `/etc/rancher/k3s/k3s.yaml` lisible par
l'utilisateur `vagrant`, pour que `kubectl` fonctionne sans `sudo`.

### Lancer

```sh
cd p1
vagrant up
```

Comptez quelques minutes au premier lancement : Vagrant télécharge la box, puis
chaque machine télécharge et installe K3s.

### Vérifier — avec le script

```sh
./scripts/verify.sh
```

Il contrôle dans l'ordre : les deux machines tournent, les hostnames
correspondent, chacune porte son IP dédiée, `k3s` est actif sur le serveur et
`k3s-agent` sur le worker, `kubectl` est installé, et les deux nœuds apparaissent
`Ready` avec les bonnes adresses.

```
=== Virtual machines ===
  [ OK ] snourryS is running
  [ OK ] snourrySW is running
=== Dedicated IPs ===
  [ OK ] snourryS has 192.168.56.110 on interface eth1
...
=== Part 1 OK ===
```

### Vérifier — à la main

Il faut savoir le faire sans le script. Connectez-vous au serveur :

```sh
vagrant ssh snourryS
```

Contrôlez l'identité et l'adresse de la machine :

```sh
hostname
ip -br -4 addr
```

`ip -br` affiche une ligne par interface ; vous cherchez `192.168.56.110/24`.
L'interface s'appelle `eth1` sur cette box, mais les distributions récentes
peuvent la nommer `enp0s8` — regardez ce que vous avez réellement plutôt que de
le supposer.

Contrôlez que K3s tourne dans le bon mode :

```sh
systemctl status k3s
```

Puis regardez le cluster :

```sh
kubectl get nodes -o wide
```

```
NAME        STATUS   ROLES                  AGE   VERSION        INTERNAL-IP
snourrys    Ready    control-plane,master   5m    v1.36.2+k3s1   192.168.56.110
snourrysw   Ready    <none>                 3m    v1.36.2+k3s1   192.168.56.111
```

Trois choses à signaler ici :

- Les noms de nœuds sont en **minuscules**, alors que les hostnames gardent leur
  majuscule. Kubelet met le hostname en minuscules parce qu'un nom de nœud doit
  être un nom DNS valide. C'est normal.
- Le worker affiche `<none>` dans ROLES. K3s n'étiquette pas ses agents ; seul
  le plan de contrôle reçoit un label de rôle. Normal également.
- INTERNAL-IP montre les adresses host-only, ce qui prouve que `--node-ip` a
  fait son travail.

Sur le worker, seul le réseau mérite un contrôle :

```sh
vagrant ssh snourrySW -c "ip -br -4 addr"
```

`kubectl` n'y fonctionnera pas — un agent n'a pas de kubeconfig, puisqu'il ne
fait pas tourner le serveur d'API.

### Nettoyer

```sh
vagrant destroy -f
```

À faire avant de passer à la partie 2. Les deux parties déclarent une machine
VirtualBox nommée `snourryS`, et VirtualBox refuse deux machines de même nom.


### Sources

- [Vagrant — configuration du provider VirtualBox](https://developer.hashicorp.com/vagrant/docs/providers/virtualbox/configuration) — `linked_clone`, `memory`, `cpus`
- [Vagrant — réseaux privés](https://developer.hashicorp.com/vagrant/docs/networking/private_network) — l'adresse host-only fixe
- [K3s — référence de configuration du serveur](https://docs.k3s.io/cli/server) — `--node-ip`, `--write-kubeconfig-mode`, `--disable`
- [K3s — référence de configuration de l'agent](https://docs.k3s.io/cli/agent) — `K3S_URL`, `K3S_TOKEN`
- [K3s — FAQ](https://docs.k3s.io/faq) — l'origine du nom
- [Kubernetes — noms des objets](https://kubernetes.io/docs/concepts/overview/working-with-objects/names/) — pourquoi les noms de nœuds sont des noms DNS en minuscules
- [Manuel VirtualBox — réseau host-only](https://www.virtualbox.org/manual/ch06.html) — la restriction 192.168.56.0/21

---

## 4. Partie 2 — K3s et trois applications

### Notions

**Pod.** La plus petite unité déployable de Kubernetes : un ou plusieurs
conteneurs partageant un espace réseau et du stockage. On crée rarement des pods
directement.

**Deployment.** Déclare *combien* de copies d'un pod on veut et *quelle* image
elles exécutent. Un contrôleur maintient ce nombre : tuez un pod, un remplaçant
apparaît. C'est ce que le sujet appelle les réplicas.

**Service.** L'IP d'un pod change à chaque recréation, on ne s'adresse donc
jamais à l'un d'eux directement. Un Service fournit un nom et une IP virtuelle
stables, et répartit la charge entre les pods correspondant à son sélecteur. Ici
chaque Service écoute sur le port 80 et transmet vers le port 8080 du conteneur.

**Ingress.** Un Service est joignable dans le cluster. Un Ingress expose des
routes HTTP vers l'extérieur, et sait router selon l'en-tête `Host` — exactement
ce qu'exige cette partie. Un Ingress n'est qu'une description ; il faut quelque
chose pour l'appliquer.

**Contrôleur d'Ingress.** Le composant qui lit les objets Ingress et configure un
vrai reverse proxy. K3s embarque **Traefik** et l'active par défaut. La partie 1
le désactivait (rien n'en avait besoin, et cela économise de la mémoire sur une
machine de 1 Go) ; la partie 2 le conserve, puisque toute la partie en dépend.

### Ce que construit cette partie

Une machine, `snourryS` en 192.168.56.110, 2 vCPU et 2048 Mo, hébergeant trois
applications routées par nom d'hôte :

| En-tête Host | Application | Réplicas |
|---|---|---|
| `app1.com` | `app-1` | 1 |
| `app2.com` | `app-2` | **3** |
| tout le reste | `app-3` | 1 |

Les trois exécutent `paulbouwer/hello-kubernetes:1.10.1`, qui sert une page
affichant la valeur de sa variable d'environnement `MESSAGE` — un moyen simple
de savoir quelle application a répondu.

### Comment fonctionne la route par défaut

`confs/ingress.yaml` déclare trois règles. Les deux premières portent un
`host:` ; la troisième non :

```yaml
    - http:                     # pas de host: correspond à tout
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app-3
```

Une règle sans hôte correspond à n'importe quel nom. Elle n'éclipse pas les deux
autres car Traefik classe les règles par spécificité :
`Host(app1.com) && PathPrefix(/)` est plus spécifique que `PathPrefix(/)` seul,
et l'emporte donc quand l'en-tête correspond.

L'Ingress précise aussi `ingressClassName: traefik`, ce qui désigne explicitement
le contrôleur à utiliser au lieu de s'en remettre au défaut.

### Lancer

```sh
cd p2
vagrant up
```

`scripts/server.sh` installe K3s, attend que le nœud soit `Ready`, puis applique
tout le contenu de `confs/` :

```sh
while ! kubectl wait --for=condition=Ready node --all --timeout=10s >/dev/null 2>&1; do
    sleep 1
done
kubectl apply -f /vagrant/confs/
```

L'attente utilise `kubectl wait` plutôt qu'un `grep` sur `Ready` — parce que
`NotReady` contient la chaîne `Ready`, et qu'un grep naïf sortirait
immédiatement.

### Vérifier — avec le script

```sh
./scripts/verify.sh
```

Au-delà des contrôles sur la machine et K3s, il attend que Traefik et les
deployments se stabilisent, puis effectue le vrai test : trois requêtes HTTP avec
des en-têtes `Host` différents, depuis la VM hôte, exactement comme le fera un
évaluateur.

Laissez quelques minutes après un `vagrant up` neuf : Traefik est déployé par un
job Helm et l'image de l'application doit être téléchargée.

### Vérifier — à la main

Regardez d'abord les objets :

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

La colonne `READY` d'`app-2` est l'exigence sur les réplicas : trois prêts sur
trois demandés. Pour les voir individuellement :

```sh
kubectl get pods -l app=app-2
```

`-l` filtre par label. Trois pods, trois noms différents, tous `Running`.

Regardez l'Ingress en détail — le sujet demande de le montrer en soutenance :

```sh
kubectl describe ingress app-ingress
```

La section `Rules` liste les trois routes et le Service visé par chacune.

Puis le test qui compte, **depuis la VM hôte** et non depuis l'intérieur :

```sh
curl -H "Host:app1.com" 192.168.56.110
curl -H "Host:app2.com" 192.168.56.110
curl 192.168.56.110
```

Les trois réponses doivent afficher respectivement `app-1`, `app-2` et `app-3`.
La dernière ne porte pas d'en-tête `Host`, elle tombe donc sur la règle par
défaut.

Pour observer la répartition de charge entre les trois réplicas, répétez la
deuxième requête plusieurs fois et regardez le nom du pod affiché sur la page :
il change.

### Nettoyer

```sh
vagrant destroy -f
```


### Sources

- [Kubernetes — Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) — réplicas et sélecteurs
- [Kubernetes — Services](https://kubernetes.io/docs/concepts/services-networking/service/) — adresse stable, `targetPort`
- [Kubernetes — Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/) — règles, `pathType`, `ingressClassName`, et la règle sans hôte
- [Traefik — routeurs et priorité](https://doc.traefik.io/traefik/routing/routers/) — pourquoi la règle par défaut n'éclipse pas les autres
- [K3s — services réseau embarqués](https://docs.k3s.io/networking/networking-services) — Traefik activé par défaut
- [paulbouwer/hello-kubernetes](https://github.com/paulbouwer/hello-kubernetes) — la variable `MESSAGE`

---

## 5. Partie 3 — K3d et Argo CD

### Notions

**Conteneur.** Un processus isolé par le noyau, pas une machine entière. Il
partage le noyau de l'hôte, démarre en millisecondes et coûte quelques
méga-octets. Isolation plus faible qu'une VM, poids incomparablement moindre.

**K3d.** K3s exécuté dans des conteneurs Docker au lieu de machines virtuelles.
Chaque « nœud » est un conteneur. Créer un cluster prend une dizaine de secondes
au lieu de plusieurs minutes. Même API Kubernetes, même `kubectl`, mêmes
manifests — seul le support change.

| | K3s en VM (parties 1–2) | K3d en Docker (partie 3+) |
|---|---|---|
| Nœud | VM complète, noyau propre | conteneur, noyau partagé |
| Démarrage | minutes | secondes |
| Isolation | forte | plus faible |
| API | identique | identique |

**NodePort.** Un type de Service qui ouvre le même port sur tous les nœuds, dans
la plage 30000–32767. Ici le Service de l'application utilise
`nodePort: 30888`.

**Le mapping de port K3d.** `--port "8888:30888@loadbalancer"` demande à K3d de
publier le port 8888 de votre machine sur le port 30888 du répartiteur de charge
du cluster. C'est ce qui permet à `curl http://localhost:8888/` d'atteindre le
pod. Le sujet impose le port 8888 ; le NodePort est un détail d'implémentation
qui doit simplement concorder des deux côtés.

**GitOps.** Un modèle de déploiement où un dépôt Git est l'unique source de
vérité. On ne lance pas `kubectl apply` à la main, on commite. Un agent dans le
cluster surveille le dépôt et fait converger le cluster vers son contenu. Deux
conséquences : l'état est auditable via l'historique Git, et toute dérive
manuelle est corrigée.

**Argo CD.** L'agent GitOps utilisé ici. Son objet `Application` dit : surveille
*ce* dépôt, à *ce* chemin, et applique-le dans *ce* namespace.

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
      selfHeal: true      # annule les modifications manuelles
      prune: true         # supprime ce qui a disparu de Git
```

`selfHeal` est le plus intéressant : supprimez le Deployment à la main et Argo CD
le remet, parce que Git le décrit toujours.

### Ce que construit cette partie

Un cluster K3d nommé `iot` avec deux namespaces, comme l'exige le sujet :

- **`argocd`** — les composants d'Argo CD
- **`dev`** — l'application déployée, `wil42/playground`, qui répond sur le port
  8888 et existe en deux tags, `v1` et `v2`

Les manifests vivent dans un dépôt GitHub public séparé,
[snourry-iot](https://github.com/Aoniii/snourry-iot), dont le nom contient le
login d'un membre de l'équipe comme demandé.

### Lancer

```sh
cd p3
sudo ./scripts/install.sh     # Docker, kubectl, K3d
./scripts/setup.sh            # cluster, namespaces, Argo CD, Application
```

`setup.sh` est rejouable : il supprime un cluster `iot` existant avant d'en créer
un nouveau, et ne crée les namespaces que s'ils manquent.

### Vérifier — avec le script

```sh
./scripts/verify.sh
```

Il contrôle les outils, le cluster, les deux namespaces, que tous les pods Argo
CD tournent, que l'Application est `Synced` et `Healthy`, que le pod de `dev`
tourne derrière un service NodePort sur 30888, et enfin que
`http://localhost:8888/` répond. Il affiche la version déployée et les
identifiants Argo CD.

### Vérifier — à la main

```sh
kubectl get nodes                    # un nœud, k3d-iot-server-0, Ready
kubectl get ns                       # argocd et dev, tous deux Active
kubectl get pods -n argocd           # tous les composants Argo CD Running
kubectl get applications -n argocd   # wil-playground, Synced, Healthy
kubectl get pods -n dev              # wil-playground-xxxxx, Running
kubectl get svc -n dev               # NodePort, 8888:30888/TCP
```

Puis le test du sujet :

```sh
curl http://localhost:8888/
```

```json
{"status":"ok", "message": "v1"}
```

Si l'Application est `OutOfSync` ou si le namespace `dev` est vide, les détails
sont ici :

```sh
kubectl describe application wil-playground -n argocd
```

Regardez `Events` et `Status.Operation State.Message`.

### L'interface web d'Argo CD

Le sujet en montre des captures, soyez donc prêt à l'afficher. Rien ne l'expose
par défaut ; ouvrez une redirection de port :

```sh
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Puis ouvrez `https://localhost:8080` et acceptez le certificat auto-signé.
Utilisateur `admin`, et le mot de passe :

```sh
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

`verify.sh` affiche cette commande et le mot de passe pour vous.

### La boucle GitOps : passer de v1 à v2

C'est la démonstration exigée par le sujet — prouver qu'une modification commitée
dans Git atteint le cluster toute seule.

**Étape 1 — changer la version dans le dépôt.**

Sur un clone de `snourry-iot` :

```sh
git clone https://github.com/Aoniii/snourry-iot.git
cd snourry-iot

sed -i 's|wil42/playground:v1|wil42/playground:v2|' manifests/deployment.yaml
git diff                       # montrer la modification avant de commiter
git commit -am "switch to v2"
git push
```

Faire un `git diff` avant de commiter vaut le coup devant un évaluateur : il voit
qu'une seule ligne change, ce qui rend la causalité évidente.

**Étape 2 — comprendre le délai.**

Argo CD ne reçoit aucune notification lors de votre push. Il exécute une *boucle
de réconciliation* : toutes les trois minutes par défaut, il relit le dépôt, le
compare au cluster et applique l'écart. Il ne se passe donc rien pendant jusqu'à
trois minutes — un silence très long devant un évaluateur.

**Étape 3 — forcer le rafraîchissement au lieu d'attendre.**

```sh
kubectl annotate application wil-playground -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

Cette annotation demande à Argo CD de relire le dépôt immédiatement. `hard`
contourne son cache de manifests, contrairement à `normal` qui peut le
réutiliser — avec un simple tag modifié, `hard` est le choix fiable.

Si vous préférez modifier l'intervalle durablement plutôt que déclencher à la
main :

```sh
kubectl -n argocd patch configmap argocd-cm --type merge \
  -p '{"data":{"timeout.reconciliation":"30s"}}'
kubectl -n argocd rollout restart deployment argocd-repo-server
```

Pratique en développement, mais gardez le défaut pour la soutenance : expliquer
*pourquoi* il y a un délai vaut mieux que le masquer.

**Étape 4 — montrer le changement.**

Suivez l'état de synchronisation :

```sh
kubectl get applications -n argocd -w
```

Il passe `Synced` → `OutOfSync` → `Synced`. Ctrl+C pour arrêter le suivi.

Suivez le remplacement du pod :

```sh
kubectl get pods -n dev -w
```

Un nouveau pod apparaît, devient `Running`, et l'ancien disparaît. Le nom change,
ce qui prouve qu'il s'agit d'un nouveau pod et non d'un redémarrage.

Puis la preuve elle-même :

```sh
curl http://localhost:8888/
```

```json
{"status":"ok", "message": "v2"}
```

Ou lancez `./scripts/verify.sh`, dont la dernière ligne indique la version
déployée.

**Étape 5 — laisser la démo rejouable.** Remettez le manifest en `v1` et
poussez, pour pouvoir recommencer.

### Démonstration bonus : l'auto-réparation

À montrer si vous avez le temps, car c'est ce qui fait comprendre le GitOps :

```sh
kubectl delete deployment wil-playground -n dev
kubectl get pods -n dev -w
```

Le Deployment revient tout seul. Vous ne l'avez pas restauré — Argo CD a constaté
que le cluster ne correspondait plus à Git et a corrigé. C'est
`selfHeal: true`.

### Nettoyer

```sh
./scripts/clean.sh            # supprime le cluster, garde les outils
sudo ./scripts/uninstall.sh   # retire Docker, kubectl et K3d
```


### Sources

- [K3d — exposer des services](https://k3d.io/stable/usage/exposing_services/) — le mapping `--port ...@loadbalancer`
- [Kubernetes — Service de type NodePort](https://kubernetes.io/docs/concepts/services-networking/service/#type-nodeport) — la plage 30000–32767
- [Argo CD — configuration déclarative](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/) — l'objet `Application`
- [Argo CD — synchronisation automatique](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/) — `selfHeal` et `prune`
- [Argo CD — FAQ](https://argo-cd.readthedocs.io/en/stable/faq/) — fréquence d'interrogation du dépôt et rafraîchissement forcé
- [Argo CD — démarrage](https://argo-cd.readthedocs.io/en/stable/getting_started/) — `argocd-initial-admin-secret`

---

## 6. Bonus — GitLab dans le cluster

### Objectif

Remplacer GitHub par une instance GitLab **hébergée dans le cluster**, et faire
qu'Argo CD la surveille. Tout ce que fait la partie 3 doit continuer de
fonctionner, avec la source de vérité hébergée localement.

### Notions supplémentaires

**Helm.** Un gestionnaire de paquets pour Kubernetes. Un *chart* est un ensemble
de manifests paramétrable ; un fichier `values.yaml` surcharge ses valeurs par
défaut ; installer un chart crée une *release* qu'on peut mettre à jour ou
restaurer. GitLab dans Kubernetes représente des dizaines d'objets — le déployer
à la main n'est pas raisonnable, d'où Helm.

**Pourquoi PostgreSQL, Redis et MinIO à part.** Le chart GitLab sait déployer ses
propres dépendances, mais ici elles sont installées séparément pour maîtriser
leurs versions et leurs ressources. GitLab a besoin d'une base de données
(PostgreSQL), d'un cache et d'une file de tâches (Redis), et d'un stockage objet
compatible S3 pour les artefacts, les uploads et le registry (MinIO).

**Versions de charts épinglées.** Dans `setup.sh` :

```sh
POSTGRESQL_VERSION="18.8.4"
REDIS_VERSION="27.0.18"
GITLAB_VERSION="10.0.0"
```

Sans `--version`, Helm installe ce qui est le plus récent *à cet instant*. Deux
exécutions à un mois d'intervalle donnent deux versions différentes. Depuis que
Bitnami a restreint l'accès gratuit à ses images en août 2025, un chart non
épinglé peut soudain référencer des images que vous ne pouvez plus télécharger.
L'épinglage est ce qui rend le bonus reproductible le jour de la soutenance.

### Ce que construit cette partie

Le même cluster que la partie 3, plus un troisième namespace :

- **`gitlab`** — GitLab, PostgreSQL, Redis, MinIO
- deux mappings de ports : `8888:30888` pour l'application, `8443:30443` pour
  l'interface web de GitLab
- `--servers-memory 12g`, un plafond sur le conteneur du cluster pour qu'il
  n'affame pas la VM hôte

L'`Application` d'Argo CD pointe désormais sur l'adresse interne au cluster :

```yaml
repoURL: http://gitlab-webservice-default.gitlab.svc.cluster.local:8181/root/snourry-iot.git
```

C'est un nom DNS interne à Kubernetes :
`<service>.<namespace>.svc.cluster.local`. Argo CD joint GitLab sans sortir du
cluster.

### Lancer

```sh
cd bonus
sudo ./scripts/install.sh     # + Helm
./scripts/setup.sh            # cluster, Argo CD, PostgreSQL, Redis, MinIO, GitLab
```

Comptez 10 à 15 minutes. Attendez que GitLab soit debout :

```sh
kubectl get pods -n gitlab
```

Quatre pods comptent avant de continuer :

```
gitlab-migrations-...       0/1   Completed    schéma de base créé
gitlab-webservice-default   2/2   Running      API et git-over-HTTP
gitlab-toolbox              1/1   Running      utilisé pour la console rails
gitlab-gitaly-0             1/1   Running      stockage des dépôts
```

`Completed` est normal pour `gitlab-migrations` et `gitlab-issuer` : ce sont des
Jobs, ils sont censés se terminer. Quelques redémarrages précoces sur
`webservice` et `sidekiq` sont normaux aussi — ils démarrent avant la fin des
migrations, échouent, puis se stabilisent.

Ensuite :

```sh
./scripts/gitlab-setup.sh
```

Ce script récupère le mot de passe root, ajoute `gitlab.gitlab.local` à
`/etc/hosts`, attend l'interface, clone les manifests depuis GitHub et les
pousse dans le GitLab local, rend le projet public pour qu'Argo CD puisse le
cloner anonymement, et applique enfin l'`Application`.

Deux détails méritent d'être connus :

- GitLab crée le projet automatiquement au premier push — c'est la fonction
  *push-to-create*.
- Le projet est recherché par chemin, pas par identifiant :
  `Project.find_by_full_path('root/snourry-iot')`. Supposer que l'ID vaut 1
  fonctionne jusqu'au jour où non, et on rend alors public le mauvais projet
  sans s'en apercevoir.

### Vérifier — avec le script

```sh
./scripts/verify.sh
```

Mêmes contrôles que la partie 3, plus les trois namespaces, les pods GitLab,
l'interface web, et le contrôle propre à cette partie :

```
=== Argo CD watches GitLab, not GitHub ===
         repoURL: http://gitlab-webservice-default.gitlab.svc.cluster.local:8181/root/snourry-iot.git
  [ OK ] the source repository is the local GitLab
```

Il échoue explicitement si l'URL contient encore `github.com` — ce qui est
précisément ce qui sépare le bonus de la partie 3.

### Vérifier — à la main

```sh
kubectl get ns                       # argocd, dev et gitlab
kubectl get pods -n gitlab           # Running ou Completed
kubectl get application wil-playground -n argocd -o jsonpath='{.spec.source.repoURL}'
kubectl get pods -n dev
curl http://localhost:8888/
```

La requête `jsonpath` est celle à montrer : elle affiche le dépôt source et rien
d'autre, la démonstration est sans ambiguïté.

Ouvrez ensuite l'interface GitLab sur `https://gitlab.gitlab.local:8443`,
acceptez le certificat auto-signé, et connectez-vous en `root` avec :

```sh
kubectl get secret gitlab-gitlab-initial-root-password -n gitlab \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

### La boucle GitOps, via GitLab

Même principe que la partie 3, mais la source de vérité est désormais locale.

**Par l'interface web**, la voie la plus visuelle :

1. Ouvrez `https://gitlab.gitlab.local:8443` et connectez-vous en `root`
2. Allez dans le projet `root/snourry-iot`
3. Ouvrez `manifests/deployment.yaml` et cliquez sur *Edit*
4. Remplacez `wil42/playground:v1` par `v2`
5. Commitez — GitLab affiche le diff avant confirmation

**En ligne de commande**, si vous préférez :

```sh
git clone https://gitlab.gitlab.local:8443/root/snourry-iot.git
cd snourry-iot
sed -i 's|playground:v1|playground:v2|' manifests/deployment.yaml
git commit -am "v2"
GIT_SSL_NO_VERIFY=true git push
```

`GIT_SSL_NO_VERIFY` est nécessaire car le certificat GitLab est auto-signé —
acceptable pour un laboratoire local, jamais en production.

**Puis, exactement comme en partie 3**, forcez le rafraîchissement plutôt
qu'attendre trois minutes :

```sh
kubectl annotate application wil-playground -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

kubectl get pods -n dev -w
curl http://localhost:8888/
```

```json
{"status":"ok", "message": "v2"}
```

Le point à souligner à voix haute : **rien d'extérieur à la machine n'est
intervenu**. Le dépôt, l'agent GitOps et l'application tournent tous dans le même
cluster.

### Nettoyer

```sh
./scripts/clean.sh
```

Contrairement à la partie 3, celui-ci retire aussi l'entrée `/etc/hosts` et le
dépôt Helm de GitLab — deux éléments d'état système qui survivraient au cluster.


### Sources

- [Helm — charts](https://helm.sh/docs/topics/charts/) et [fichiers de valeurs](https://helm.sh/docs/chart_template_guide/values_files/)
- [Helm — `helm upgrade`](https://helm.sh/docs/helm/helm_upgrade/) — `--install`, `--wait`, `--version`
- [Chart GitLab — documentation](https://docs.gitlab.com/charts/) et [paramètres globaux](https://docs.gitlab.com/charts/charts/globals.html)
- [Bitnami — restriction de l'accès gratuit aux images, août 2025](https://github.com/bitnami/containers/issues/83267) — l'annonce que Helm lui-même signale pendant l'installation
- [MinIO — documentation Kubernetes](https://min.io/docs/minio/kubernetes/upstream/) et [`mc mb`](https://min.io/docs/minio/linux/reference/minio-mc/mc-mb.html)
- [Kubernetes — DNS des services](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/) — la forme `<service>.<namespace>.svc.cluster.local`

---

## 7. Dépannage

Chaque entrée ci-dessous a réellement été rencontrée pendant la construction de
ce projet.

### `vagrant up` échoue : une VM de ce nom existe déjà

Le dossier `.vagrant` a été supprimé ou déplacé sans `vagrant destroy`, Vagrant a
donc perdu la trace d'une machine que VirtualBox possède toujours.

```sh
VBoxManage list vms
VBoxManage controlvm snourryS poweroff
VBoxManage unregistervm snourryS --delete
rm -rf p1/.vagrant p2/.vagrant
```

Si elle reste verrouillée, tuez le processus résiduel (`pkill -f snourryS`), puis
`VBoxSVC` en dernier recours — il se relance seul.

### La clé privée doit appartenir à l'utilisateur qui lance Vagrant

Vous lancez Vagrant depuis un dossier partagé VirtualBox. Le système de fichiers
`vboxsf` impose le propriétaire et les permissions via ses options de montage, la
clé SSH générée ne peut donc jamais satisfaire les exigences de SSH.

Copiez le projet sur le disque de la VM. Vous pouvez continuer à éditer via le
dossier partagé et synchroniser avant chaque test :

```sh
rsync -a --delete --exclude '.vagrant' /media/sf_projet/ ~/projet/
```

### Des pods bloqués en Pending, d'autres en Completed

Presque toujours une saturation du disque. En dessous de 15 % libres, kubelet
pose un taint sur le nœud et plus rien ne peut être planifié.

```sh
df -h /
kubectl describe node | grep -A15 Conditions
```

Libérez de l'espace — les VMs Vagrant des autres parties sont en général le plus
gros gain — puis recréez le cluster. Le taint disparaît de lui-même une fois
l'espace revenu.

### `kubectl wait` échoue avec NotFound ou « no matching resources found »

`kubectl wait` n'attend pas qu'un objet soit *créé* ; il échoue immédiatement
s'il n'existe pas. Juste après un `helm install` ou un `kubectl apply`, le
Deployment existe mais pas encore ses pods.

Attendez sur un objet créé de façon synchrone, pas sur un pod :

```sh
kubectl rollout status deployment/minio -n gitlab --timeout=300s
helm upgrade --install ... --wait --timeout 10m
```

### vboxdrv n'est pas chargé

Le module DKMS n'a pas compilé, ou Secure Boot refuse un module non signé.

```sh
dkms status
mokutil --sb-state
sudo /sbin/vboxconfig
```

`install-host.sh` contrôle ce point avant de conclure, il ne vous annoncera donc
pas un succès sur une installation cassée.

### Tout est rouge juste après avoir lancé une partie

Les scripts de vérification attendent ce qui doit l'être, mais un cluster neuf
peut mettre plusieurs minutes à télécharger ses images. Comparez la colonne `AGE`
entre les sections de la sortie : si les premiers contrôles se sont exécutés à
2 minutes et les derniers à 7, c'est simplement que le lancement était trop tôt.
Relancez.

### Argo CD reste OutOfSync

```sh
kubectl describe application wil-playground -n argocd
```

Le champ `Message` nomme généralement la cause : dépôt injoignable, projet privé,
chemin incorrect.


### Sources

- [Kubernetes — éviction sous pression du nœud](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/) — les seuils par défaut, dont `imagefs.available<15%`
- [Kubernetes — `kubectl wait`](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_wait/) — pourquoi il échoue au lieu d'attendre quand l'objet manque
- [Manuel VirtualBox — dossiers partagés](https://www.virtualbox.org/manual/ch04.html) — les limites de `vboxsf` sur le propriétaire et les permissions

---

## 8. Aide-mémoire

### Vagrant

| Commande | Effet |
|---|---|
| `vagrant up` | créer et démarrer les machines |
| `vagrant ssh <nom>` | se connecter |
| `vagrant ssh <nom> -c "cmd"` | exécuter une commande et sortir |
| `vagrant provision` | rejouer les scripts de provisionnement |
| `vagrant reload` | redémarrer |
| `vagrant halt` | éteindre |
| `vagrant destroy -f` | supprimer complètement |
| `vagrant status` | état courant |
| `vagrant snapshot save <nom>` | instantané |
| `vagrant snapshot restore <nom>` | restaurer en quelques secondes |

### kubectl

| Commande | Effet |
|---|---|
| `kubectl get nodes -o wide` | les nœuds avec leurs adresses |
| `kubectl get pods -A` | tous les pods de tous les namespaces |
| `kubectl get pods -n <ns> -w` | suivre en direct |
| `kubectl get pods -l app=app-2` | filtrer par label |
| `kubectl describe <type> <nom>` | détail et événements |
| `kubectl logs <pod> -n <ns>` | journaux |
| `kubectl apply -f <fichier\|dossier>` | appliquer des manifests |
| `kubectl rollout status deployment/<nom>` | attendre un déploiement |
| `kubectl port-forward svc/<nom> -n <ns> 8080:443` | exposer localement |

### K3d et Argo CD

| Commande | Effet |
|---|---|
| `k3d cluster list` | lister les clusters |
| `k3d cluster delete iot` | supprimer le cluster |
| `kubectl get applications -n argocd` | état de synchronisation et de santé |
| `kubectl annotate application <app> -n argocd argocd.argoproj.io/refresh=hard --overwrite` | forcer un rafraîchissement immédiat |

### Helm

| Commande | Effet |
|---|---|
| `helm list -n gitlab` | releases installées et versions de charts |
| `helm get values <release> -n <ns>` | valeurs réellement appliquées |
| `helm show chart <chart>` | métadonnées du chart, dont sa version |
| `helm upgrade --install ... --wait` | installer ou mettre à jour en attendant |

