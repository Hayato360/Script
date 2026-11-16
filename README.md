# install-rancher


bash <(curl -s **URL RAW**)

bash <(curl -s https://raw.githubusercontent.com/Jerlamai69/rancher/refs/heads/main/haproxy.sh?token=GHSAT0AAAAAADHONWJQ66GDN2J22XWIBRWC2DXOYEQ)

## Rancher v2.15+ Monitoring (kube-prometheus-stack + Monitoring Dashboards)

Run on the Rancher VM as root, with the downstream cluster kubeconfig:

```bash
bash <(curl -s https://raw.githubusercontent.com/Hayato360/Script/refs/heads/main/rancher-monitoring-v2.sh)
```

## OLS Observe check (read-only: Prometheus / Cert / Blackbox)

Run on a master node or the Rancher VM (needs kubectl + kubeconfig). Changes nothing:

```bash
bash <(curl -s https://raw.githubusercontent.com/Hayato360/Script/refs/heads/main/observe-check.sh)
```

## Blackbox add-on (for clusters that already have Cert / remoteWrite)

Installs blackbox-exporter + CoreDNS and Rancher /healthz probes (no TCP probe).
Asks you for: cluster name, Rancher URL, DNS target. Everything else is auto-detected.

```bash
bash <(curl -s https://raw.githubusercontent.com/Hayato360/Script/refs/heads/main/blackbox-install.sh)
```
