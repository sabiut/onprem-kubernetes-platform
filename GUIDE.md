# Step-by-step guide: self-managed Kubernetes on your own machine

You will build the same layers a real on-prem team runs, one tool at a time:

```
Step 1  Terraform  -> network + 3 VMs                 (the "data centre")
Step 2  Ansible    -> OS, PostgreSQL, Kubernetes      (the servers)
Step 3  Helm       -> Prometheus + Grafana            (platform)
Step 4  Helm       -> the web app                     (application)
Step 5  Grafana    -> watch it all
Step 6  Tear down
```

All commands run from the project folder:

```bash
cd onprem-kubernetes-platform
```

---

## Step 0: Prepare (2 minutes)

The VMs need about **6.5 GB of free RAM**. Close any heavy applications, then check:

```bash
free -h                         # "available" column: 6.5G or more
```

Check the tools are there (all should print a version):

```bash
terraform version && ansible --version | head -1 && helm version --short && kubectl version --client
```

---

## Step 1: Terraform builds the infrastructure (3-5 minutes)

```bash
make infra
```

**What happens**

| Terraform creates | File |
|---|---|
| An SSH key for Ansible (`.keys/id_ed25519`) | `terraform/main.tf` |
| A private network `10.17.0.0/24` | `terraform/main.tf` |
| One Debian 13 base disk, then a disk per VM built on it | `terraform/main.tf` |
| cloud-init settings per VM: hostname, user `debian`, SSH key, fixed IP | `terraform/templates/` |
| 3 VMs: `k8s-cp1` 10.17.0.10, `k8s-w1` 10.17.0.21, `db1` 10.17.0.30 | `terraform/variables.tf` |
| **The Ansible inventory**, so Ansible knows the VMs | `ansible/inventories/local/hosts.yml` |

That last row is the hand-off: Terraform knows what it built and tells Ansible.

**Check it worked**

```bash
virsh -c qemu:///system list                   # 3 VMs: running
cat ansible/inventories/local/hosts.yml        # groups: k3s_server, k3s_agents, dbservers
ssh -i .keys/id_ed25519 debian@10.17.0.10      # log in to a VM, then type: exit
```

**Learn**

```bash
cd terraform && terraform state list && cd ..  # every resource Terraform manages
```

---

## Step 2: Ansible configures the servers (about 5 minutes)

```bash
make configure
```

Same as running `cd ansible && ansible-playbook playbooks/site.yml`.

**What happens** (in `ansible/playbooks/site.yml`, play by play)

| Play | Hosts | Role | Does |
|---|---|---|---|
| 1 | all 3 VMs | `common` | Waits for boot, installs packages, sets timezone, fills `/etc/hosts`, starts time sync |
| 2 | `db1` | `postgresql` | Installs PostgreSQL, opens it to the lab network, creates user `appuser` and database `appdb` |
| 3 | `k8s-cp1` | `k3s_server` | Installs Kubernetes control plane, reads the join token, copies the kubeconfig to `kubeconfig/local.yaml` |
| 4 | `k8s-w1` | `k3s_agent` | Installs Kubernetes worker and joins it using the token from play 3 |
| 5 | your laptop | (tasks) | Waits until all nodes are Ready and prints them |

The DB password is generated once into `.keys/db_password`. Helm uses it in Step 4.

**Check it worked**

```bash
export KUBECONFIG=$PWD/kubeconfig/local.yaml   # use this in every new terminal
kubectl get nodes -o wide                      # k8s-cp1 and k8s-w1: Ready
```

**Learn**

```bash
make configure                                 # run again: almost everything "ok", nothing "changed" (idempotent)
cd ansible
ansible all -m ping                            # ad-hoc command to all VMs
ansible dbservers -b -m command -a "systemctl status postgresql --no-pager"
ansible-inventory --graph
cd ..
```

---

## Step 3: Helm installs monitoring (3-5 minutes)

```bash
make monitoring
```

**What happens**

- Creates namespace `monitoring` and a secret `grafana-admin` with a random password.
- Installs the `kube-prometheus-stack` chart (version pinned in the `Makefile`) with settings from
  `helm/values/monitoring-local.yaml`:
  - **Prometheus** collects metrics
  - **Grafana** draws dashboards
  - **Alertmanager** sends alerts
  - **node-exporter** collects VM metrics (CPU, RAM, disk)
  - **kube-state-metrics** collects Kubernetes object state (pods, deployments, restarts)

It goes in **before** the app because it installs the `ServiceMonitor` type the app chart uses.

**Check it worked**

```bash
kubectl -n monitoring get pods                 # all Running
helm list -A                                   # release "kps"
```

---

## Step 4: Helm deploys the app (1-2 minutes)

```bash
make deploy
make status
```

**What happens**

`helm upgrade --install webapp helm/charts/webapp -f helm/values/values-local.yaml --set database.password=...`

| Chart template | Creates |
|---|---|
| `secret.yaml` | DB connection details (host 10.17.0.30 from the values file, password from `.keys/db_password`) |
| `configmap.yaml` | The web page and nginx config |
| `deployment.yaml` | 2 pods. Each starts with a `db-check` init container that connects to PostgreSQL, then nginx + a metrics exporter |
| `service.yaml` | Stable address for the pods |
| `ingress.yaml` | Traefik route so you can reach it on http://10.17.0.10/ |
| `servicemonitor.yaml` | Tells Prometheus to scrape the app's metrics |

**Check it worked**

- App: <http://10.17.0.10/>
- Database proof: <http://10.17.0.10/db.txt> (PostgreSQL version and server time, read from db1)

```bash
kubectl -n demo get pods,svc,ingress
kubectl -n demo logs deploy/webapp -c db-check
```

**Learn: change and roll back with Helm**

```bash
# 1. Edit helm/values/values-local.yaml: change "message:" and "replicaCount: 3"
make deploy
kubectl -n demo get pods                       # new pods replaced the old ones
helm -n demo history webapp                    # revisions 1 and 2
helm -n demo rollback webapp 1                 # back to the first version
```

---

## Step 5: Look at monitoring

```bash
make grafana                                   # prints user/password, keep this terminal open
```

Open <http://localhost:3000> and log in. Then **Dashboards** and try:

| Dashboard | Shows |
|---|---|
| Kubernetes / Compute Resources / Cluster | CPU and memory of the whole cluster |
| Kubernetes / Compute Resources / Namespace (Pods) | Pick namespace `demo`: your app's pods |
| Node Exporter / Nodes | Each VM: CPU, RAM, disk, network |

Prometheus itself (in another terminal, with `KUBECONFIG` exported):

```bash
make prometheus                                # http://localhost:9090
```

- **Status > Targets**: everything being scraped, including `serviceMonitor/demo/webapp`
- Query: `rate(nginx_http_requests_total[5m])`, then refresh the app page a few times and query again

**Learn: watch Kubernetes heal itself**

```bash
kubectl -n demo delete pod -l app.kubernetes.io/name=webapp --wait=false
kubectl -n demo get pods -w                    # new pods appear straight away (Ctrl+C to stop)
```

The restart also shows on the Grafana pod dashboard.

---

## Step 6: Tear down

```bash
make destroy
```

Removes the Helm releases, VMs, disks and network. Run `make all` to build it all again (about 15 minutes).

To stop the VMs without deleting them (saves RAM, keeps everything):

```bash
for vm in k8slab-k8s-cp1 k8slab-k8s-w1 k8slab-db1; do virsh -c qemu:///system shutdown $vm; done
for vm in k8slab-db1 k8slab-k8s-cp1 k8slab-k8s-w1; do virsh -c qemu:///system start $vm; done   # later
```

---

## Troubleshooting

| Problem | Likely cause | Fix |
|---|---|---|
| Step 1: `Permission denied` on a `.qcow2` or `.iso` | AppArmor blocks QEMU from the lab disks | As root: `echo '  /var/lib/libvirt/images/k8slab-* rwk,' > /etc/apparmor.d/abstractions/libvirt-qemu.d/k8slab`, then remove the half-made VMs (`virsh -c qemu:///system undefine k8slab-<name>`) and rerun `make infra` |
| Step 1: `domain 'k8slab-...' already exists` | A failed run left VM definitions Terraform does not know about | `for vm in k8slab-k8s-cp1 k8slab-k8s-w1 k8slab-db1; do virsh -c qemu:///system undefine $vm; done`, then `make infra` |
| Step 1: network overlaps an existing one | Another network uses 10.17.0.0/24 | Change `network_cidr` and the IPs in `terraform/variables.tf` |
| Step 2: `UNREACHABLE` | VM still booting | Wait 30 seconds, run `make configure` again |
| Step 3/4: pods stuck `Pending` | Not enough memory on the VMs | `kubectl describe pod <name> -n <ns>`; free host RAM or raise `memory` in `variables.tf` |
| Step 4: `db-check` keeps waiting | App can't reach PostgreSQL | `kubectl -n demo logs deploy/webapp -c db-check`; `ansible dbservers -b -m command -a "ss -ltnp"` |
| `kubectl` talks to the wrong cluster | `KUBECONFIG` not set in this terminal | `export KUBECONFIG=$PWD/kubeconfig/local.yaml` |
| Desktop very slow | Host out of RAM | Shut the VMs down (Step 6) and close other apps |
