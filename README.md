# onprem-kubernetes-platform

A self-managed Kubernetes cluster built from nothing on local KVM virtual machines, the way an
on-prem team would run it. Terraform creates the machines, Ansible configures them, and Helm
deploys the monitoring stack and the application. One `make all` builds the whole thing in about
15 minutes, and `make destroy` removes it.

| Layer | Tool | Creates |
|---|---|---|
| Infra | Terraform (`terraform/`) | Private network 10.17.0.0/24, 3 Debian 13 VMs, an SSH key, and the Ansible inventory file |
| Servers | Ansible (`ansible/`) | OS baseline on all VMs, PostgreSQL on db1, k3s control plane on k8s-cp1, k3s worker on k8s-w1, and the kubeconfig |
| Platform | built into k3s + Helm | Traefik ingress, CoreDNS, metrics-server (k3s); Prometheus, Grafana and Alertmanager (kube-prometheus-stack) |
| App | Helm (`helm/charts/webapp`) | A web app that proves it can reach PostgreSQL on the db1 VM, with a metrics exporter and ServiceMonitor |

    k8s-cp1  10.17.0.10  control plane   2 GB
    k8s-w1   10.17.0.21  worker          3 GB (runs the monitoring stack)
    db1      10.17.0.30  PostgreSQL      1 GB

## Requirements

- Linux host with KVM and libvirt (`qemu:///system`), and about 6.5 GB of free RAM
- Terraform 1.6 or newer, Ansible, Helm and kubectl

## Run it

    make infra       # Terraform: network + VMs (first run downloads the Debian image)
    make configure   # Ansible: OS, PostgreSQL, k3s
    make monitoring  # Helm: Prometheus + Grafana
    make deploy      # Helm: the app
    make status      # open http://10.17.0.10/ and http://10.17.0.10/db.txt
    make grafana     # http://localhost:3000 (prints the admin password)
    make prometheus  # http://localhost:9090
    make destroy     # remove VMs and network

    make all         # infra, configure, monitoring and deploy in one go

    ssh -i .keys/id_ed25519 debian@10.17.0.10    # log in to a VM

[GUIDE.md](GUIDE.md) walks through each step, how to check it worked, and troubleshooting.

## Hand-offs between tools

- Terraform writes `ansible/inventories/local/hosts.yml`, so Ansible knows the VMs.
- Ansible writes `kubeconfig/local.yaml` (cluster access) and `.keys/db_password`.
- Helm reads both to deploy the app.

## Secrets

Nothing sensitive is committed. The SSH key, database password, Grafana admin password and
kubeconfig are generated on each build and kept in `.keys/` and `kubeconfig/`, which are ignored
by git along with the Terraform state. The database password reaches Helm with `--set` at deploy
time.

## Monitoring

Prometheus collects metrics, Grafana shows them, Alertmanager sends alerts.

- Grafana > Dashboards: "Kubernetes / Compute Resources / Node (Pods)" and "Node Exporter / Nodes" show the VMs.
- The app's metrics come from an nginx exporter sidecar; its ServiceMonitor tells Prometheus to scrape it.
  In Prometheus try: `rate(nginx_http_requests_total[5m])`.
- Control-plane scraping (scheduler, controller-manager, etcd) is off: k3s runs them inside one binary.

## Beyond a lab

The libvirt provider is the only part tied to this setup. On a real on-prem site the Terraform
layer would target vSphere, Proxmox or OpenStack, and the Ansible and Helm layers stay the same.
