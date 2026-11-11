#!/bin/bash
#############################################################################
# Rancher v2.15+ Monitoring (Grafana + Prometheus + Alertmanager)
#
# From Rancher v2.15 the old "Monitoring" app is gone. This script installs:
#   1. kube-prometheus-stack          (prometheus-community)  -> Prometheus/Grafana/Alertmanager
#   2. rancher-monitoring-dashboards  (Rancher "Monitoring Dashboards" chart)
#      -> Rancher dashboards + proxy, so the Monitoring tab in Rancher UI works
#
# Run on : the Rancher server VM, as root
# Needs  : kubectl + kubeconfig of the DOWNSTREAM cluster (Rancher UI > cluster > Download KubeConfig)
#          a StorageClass for the Prometheus PVC (e.g. nfs-client)
#
# Usage  : bash <(curl -s https://raw.githubusercontent.com/Hayato360/Script/refs/heads/main/rancher-monitoring-v2.sh)
#
# Optional env overrides (otherwise asked / defaulted):
#   KUBECONFIG=/root/.kube/kubeconfig  STORAGE_CLASS=nfs-client  PVC_SIZE=50Gi
#   RETENTION=30d  RETENTION_SIZE=40GB  CLUSTER_ID=c-m-xxxx  CLUSTER_NAME=mycluster
#   INSTALL_DASHBOARDS=y  DASHBOARDS_VERSION=110.0.1+up0.1.4  WORKDIR=/root/monitoring
#############################################################################

bold=$(tput bold 2>/dev/null)
normal=$(tput sgr0 2>/dev/null)
RED='\e[0;31m'
GREEN='\e[0;32m'
YELLOW='\e[0;33m'
NC='\e[0m'

NS=cattle-monitoring-system
KPS_RELEASE=kube-prometheus-stack
DASH_RELEASE=rancher-monitoring-dashboards
WORKDIR=${WORKDIR:-/root/monitoring}
VALUES_FILE=$WORKDIR/values.yaml
DASHBOARDS_VERSION=${DASHBOARDS_VERSION:-110.0.1+up0.1.4}

step() { echo ""; echo -e "${GREEN}${bold}==> $*${normal}${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }
fail() { echo -e "${RED}[ERROR] $*${NC}"; exit 1; }

# ask VAR "question" "default" : keep env value if set, otherwise prompt with default
ask() {
        local var=$1 question=$2 default=$3 answer
        if [[ -n "${!var}" ]]; then
                echo "$question: ${!var} (from env)"
                return
        fi
        read -r -p "$question [$default]: " answer
        printf -v "$var" '%s' "${answer:-$default}"
}

echo ""
echo -e "${RED}########################################################################################${NC}"
echo -e "  Install ${bold}Rancher v2.15+ Monitoring${normal} (kube-prometheus-stack + Monitoring Dashboards)"
echo -e "${RED}########################################################################################${NC}"

#############################################################
step "1. Pre-check"
#############################################################
[[ $EUID -eq 0 ]] || fail "Run as root (sudo su first)"
command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"

ask KUBECONFIG "Kubeconfig of the downstream cluster" "/root/.kube/kubeconfig"
[[ -f "$KUBECONFIG" ]] || fail "Kubeconfig $KUBECONFIG not found (Rancher UI > cluster > Download KubeConfig)"
export KUBECONFIG

kubectl get nodes -o wide || fail "Cannot reach the cluster with $KUBECONFIG"

#############################################################
step "2. Settings"
#############################################################
echo "StorageClasses in this cluster:"
kubectl get sc
default_sc=$(kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}')
ask STORAGE_CLASS "StorageClass for Prometheus PVC" "${default_sc:-nfs-client}"
kubectl get sc "$STORAGE_CLASS" >/dev/null 2>&1 || fail "StorageClass '$STORAGE_CLASS' does not exist"

ask PVC_SIZE "Prometheus PVC size" "50Gi"
ask RETENTION "Prometheus retention (time)" "30d"
ask RETENTION_SIZE "Prometheus retention (max size, keep below the PVC/NFS disk size)" "40GB"

ask INSTALL_DASHBOARDS "Install Rancher 'Monitoring Dashboards' chart too (enables the Monitoring tab)? (y/n)" "y"
if [[ $INSTALL_DASHBOARDS == "y" || $INSTALL_DASHBOARDS == "Y" ]]; then
        # Rancher kubeconfig server URL looks like https://<rancher>/k8s/clusters/c-m-xxxxxxx
        server_url=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
        detected_id=$(echo "$server_url" | sed -n 's#.*/k8s/clusters/\([^/]*\).*#\1#p')
        detected_name=$(kubectl config current-context)
        [[ -z "$detected_id" ]] && warn "Could not detect the Rancher cluster ID from $server_url (see Rancher UI URL: .../c/<cluster-id>/...)"
        ask CLUSTER_ID "Rancher cluster ID (c-m-xxxx, 'local' for the Rancher local cluster)" "$detected_id"
        [[ -n "$CLUSTER_ID" ]] || fail "Cluster ID is required for the Monitoring Dashboards chart"
        ask CLUSTER_NAME "Rancher cluster name" "$detected_name"
fi

#############################################################
step "3. Helm"
#############################################################
if command -v helm >/dev/null 2>&1; then
        echo "helm already installed: $(helm version --short)"
else
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash || fail "helm install failed"
fi

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update || fail "helm repo add prometheus-community failed"
if [[ $INSTALL_DASHBOARDS == "y" || $INSTALL_DASHBOARDS == "Y" ]]; then
        helm repo add rancher-charts https://charts.rancher.io --force-update || fail "helm repo add rancher-charts failed"
fi
helm repo update || fail "helm repo update failed"

#############################################################
step "4. Namespace $NS"
#############################################################
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - || fail "create namespace failed"

#############################################################
step "5. values.yaml -> $VALUES_FILE"
#############################################################
mkdir -p "$WORKDIR"
if [[ -f "$VALUES_FILE" ]]; then
        cp "$VALUES_FILE" "$VALUES_FILE.bak-$(date +%F-%H%M%S)"
        echo "Existing values.yaml backed up"
fi
cat > "$VALUES_FILE" <<EOF
grafana:
  # Do NOT set root_url / serve_from_sub_path (the Monitoring Dashboards proxy handles it)
  grafana.ini:
    security:
      allow_embedding: true
    auth:
      disable_login_form: false
    auth.anonymous:
      enabled: true
      org_role: Viewer
    dashboards:
      default_home_dashboard_path: /tmp/dashboards/rancher-default-home.json
    users:
      auto_assign_org_role: Viewer
prometheus:
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    probeSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    retention: ${RETENTION}
    retentionSize: ${RETENTION_SIZE}
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: ${STORAGE_CLASS}
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: ${PVC_SIZE}
kubeEtcd:
  enabled: false
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeProxy:
  enabled: false
prometheus-node-exporter:
  tolerations:
    # run node-exporter on control-plane/etcd nodes too (RKE2 masters are tainted)
    - operator: Exists
EOF
cat "$VALUES_FILE"

#############################################################
step "6. Install $KPS_RELEASE (takes 2-5 min)"
#############################################################
helm upgrade --install "$KPS_RELEASE" prometheus-community/kube-prometheus-stack \
        -n "$NS" -f "$VALUES_FILE" --wait --timeout 10m \
        || fail "$KPS_RELEASE install failed. Check: kubectl -n $NS get pods,pvc"

#############################################################
if [[ $INSTALL_DASHBOARDS == "y" || $INSTALL_DASHBOARDS == "Y" ]]; then
step "7. Install $DASH_RELEASE $DASHBOARDS_VERSION (cluster $CLUSTER_NAME / $CLUSTER_ID)"
#############################################################
        helm upgrade --install "$DASH_RELEASE" rancher-charts/rancher-monitoring-dashboards \
                -n "$NS" --version "$DASHBOARDS_VERSION" \
                --set global.cattle.clusterId="$CLUSTER_ID" \
                --set global.cattle.clusterName="$CLUSTER_NAME" \
                --wait --timeout 10m \
                || fail "$DASH_RELEASE install failed. You can install it from Rancher UI: Apps > Charts > Monitoring Dashboards (namespace $NS)"
else
        step "7. Skipped Monitoring Dashboards"
        echo "Install it later from Rancher UI: Apps > Charts > Monitoring Dashboards > Install (namespace $NS, Next > Install)"
fi

#############################################################
step "8. Result"
#############################################################
helm list -n "$NS"
echo ""
kubectl -n "$NS" get pods -o wide
echo ""
kubectl -n "$NS" get pvc
echo ""
kubectl -n "$NS" get ds

grafana_pw=$(kubectl -n "$NS" get secret "$KPS_RELEASE-grafana" -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)

echo ""
echo -e "${GREEN}########################################################################################${NC}"
echo -e "  ${bold}Done${normal}"
echo -e "  Rancher UI > cluster ${bold}${CLUSTER_NAME:-<cluster>}${normal} > Monitoring > Grafana (refresh the page)"
echo -e "  Grafana admin user : ${bold}admin${normal}"
echo -e "  Grafana admin pass : ${bold}${grafana_pw}${normal}"
echo -e "  values.yaml        : $VALUES_FILE"
echo -e "${GREEN}########################################################################################${NC}"
