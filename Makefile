# Self-managed Kubernetes, locally:
#   Terraform -> VMs + network
#   Ansible   -> OS, PostgreSQL, k3s
#   Helm      -> monitoring (Prometheus + Grafana), then the app
export KUBECONFIG := $(CURDIR)/kubeconfig/local.yaml
NS := demo
MON := monitoring
KPS_VERSION := 91.9.0

.PHONY: all infra configure monitoring deploy status grafana prometheus destroy

all: infra configure monitoring deploy

infra:            ## 1. Terraform: create network + VMs, write Ansible inventory
	cd terraform && terraform init -upgrade && terraform plan && terraform apply -auto-approve

configure:        ## 2. Ansible: OS setup, PostgreSQL on db1, k3s cluster
	cd ansible && ansible-playbook playbooks/site.yml

monitoring:       ## 3. Helm: Prometheus + Grafana (before the app, so its ServiceMonitor is picked up)
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	kubectl create namespace $(MON) --dry-run=client -o yaml | kubectl apply -f -
	kubectl -n $(MON) get secret grafana-admin >/dev/null 2>&1 || \
	  kubectl -n $(MON) create secret generic grafana-admin \
	    --from-literal=admin-user=admin --from-literal=admin-password="$$(openssl rand -hex 12)"
	helm upgrade --install kps prometheus-community/kube-prometheus-stack \
	  --version $(KPS_VERSION) -n $(MON) \
	  -f helm/values/monitoring-local.yaml --wait --timeout 10m

deploy:           ## 4. Helm: deploy the app (password created by Ansible)
	helm upgrade --install webapp helm/charts/webapp \
	  --namespace $(NS) --create-namespace \
	  -f helm/values/values-local.yaml \
	  --set database.password="$$(cat .keys/db_password)" \
	  --wait --timeout 5m

status:
	kubectl get nodes -o wide
	kubectl -n $(NS) get pods,svc,ingress
	kubectl -n $(MON) get pods
	@echo; echo "App: http://10.17.0.10/   DB check: http://10.17.0.10/db.txt"

grafana:          ## Open Grafana on http://localhost:3000 (Ctrl+C to stop)
	@echo "user: admin  password: $$(kubectl -n $(MON) get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)"
	kubectl -n $(MON) port-forward svc/kps-grafana 3000:80

prometheus:       ## Open Prometheus on http://localhost:9090
	kubectl -n $(MON) port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090

destroy:          ## Remove everything
	-helm uninstall webapp -n $(NS)
	-helm uninstall kps -n $(MON)
	cd terraform && terraform destroy -auto-approve
	rm -f kubeconfig/local.yaml
