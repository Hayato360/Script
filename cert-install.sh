#!/bin/bash
#############################################################################
# Install Cert monitoring for OLS Observe ("Certificate Monitoring" dashboard)
#
#   1. Helm chart enix/x509-certificate-exporter (ns of Prometheus, e.g. cattle-monitoring-system)
#      - DaemonSet on control-plane nodes, reads cert files (default RKE2: /var/lib/rancher/rke2/server/tls/...)
#      - ServiceMonitor labelled so Prometheus scrapes it
#   2. remoteWrite "<cluster>-cert" -> metrics-gateway.olsxops.com, tenant rancher-cert, keep x509_.*
#      (skipped if an entry to tenant rancher-cert already exists)
#      creates secret mimir-auth if missing (username default mimiradmin, password asked)
#
# Skips step 1 if an x509 exporter is already installed (asks).
#
# Run on : a master node or the Rancher VM, as root, with kubeconfig of the cluster
# Usage  : bash <(curl -s https://raw.githubusercontent.com/Hayato360/Script/refs/heads/main/cert-install.sh)
#
# Optional env (otherwise detected / asked):
#   CLUSTER_NAME=mycluster  PUBLIC_IP=x.x.x.x  CERT_DIRS="/dir1/ /dir2/"
#   MIMIR_USER=mimiradmin MIMIR_PASS=...  X509_CHART_VERSION=<ver>  KUBECONFIG=...  ASSUME_YES=y
#############################################################################

PATH=$PATH:/var/lib/rancher/rke2/bin:/usr/local/bin
RW_URL=https://metrics-gateway.olsxops.com/api/v1/push
CERT_TENANT=${CERT_TENANT:-rancher-cert}
SECRET=mimir-auth
X509_RELEASE=x509-certificate-exporter
WORKDIR=${WORKDIR:-/root/cert}

bold=$(tput bold 2>/dev/null)
normal=$(tput sgr0 2>/dev/null)
RED='\e[0;31m'
GREEN='\e[0;32m'
YELLOW='\e[0;33m'
NC='\e[0m'

step() { echo ""; echo -e "${GREEN}${bold}==> $*${normal}${NC}"; }
ok()   { echo -e "  ${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }
info() { echo -e "         $*"; }
fail() { echo -e "  ${RED}[ERROR]${NC} $*"; exit 1; }

ask() {
        local var=$1 question=$2 default=$3 answer
        if [[ -n "${!var}" ]]; then
                echo "  $question: ${!var} (from env)"
                return
        fi
        read -r -p "  $question [$default]: " answer
        printf -v "$var" '%s' "${answer:-$default}"
}

TMPD=""
cleanup() { [[ -n "$TMPD" ]] && rm -rf "$TMPD"; }
trap cleanup EXIT
tmpdir() { [[ -z "$TMPD" ]] && TMPD=$(mktemp -d /tmp/cert-install.XXXXXX); }
ARCH=$(uname -m); [[ "$ARCH" == aarch64 ]] && ARCH=arm64 || ARCH=amd64

echo ""
echo -e "${RED}########################################################################################${NC}"
echo -e "  Install ${bold}Cert monitoring${normal} (x509-certificate-exporter + remoteWrite tenant $CERT_TENANT)"
echo -e "${RED}########################################################################################${NC}"

#############################################################
step "1. Pre-check"
#############################################################
[[ $EUID -eq 0 ]] || fail "Run as root (sudo su first)"

if [[ -z "$KUBECONFIG" ]]; then
        for f in /etc/rancher/rke2/rke2.yaml /etc/rancher/k3s/k3s.yaml /root/.kube/config /root/.kube/kubeconfig \
                 /root/kube_config_*.yml /home/*/.kube/config; do
                if [[ -r "$f" ]]; then export KUBECONFIG=$f; break; fi
        done
fi
[[ -n "$KUBECONFIG" ]] || fail "No kubeconfig found. Rancher UI > cluster > Download KubeConfig, then: KUBECONFIG=/root/.kube/<cluster>.yaml bash <(curl ...)"
info "KUBECONFIG = $KUBECONFIG"

if ! command -v kubectl >/dev/null 2>&1; then
        if command -v k3s >/dev/null 2>&1; then
                kubectl() { k3s kubectl "$@"; }
        else
                warn "kubectl not found -> downloading a temporary kubectl to /tmp (removed at exit)"
                tmpdir
                KV=$(curl -sL -m 15 https://dl.k8s.io/release/stable.txt)
                curl -sL -m 120 -o "$TMPD/kubectl" "https://dl.k8s.io/release/$KV/bin/linux/$ARCH/kubectl" && chmod +x "$TMPD/kubectl" \
                        && "$TMPD/kubectl" version --client >/dev/null 2>&1 || fail "Cannot download kubectl"
                PATH=$TMPD:$PATH
        fi
fi
if ! command -v helm >/dev/null 2>&1; then
        warn "helm not found -> downloading a temporary helm to /tmp (removed at exit)"
        tmpdir
        HV=${HELM_VERSION:-v3.17.3}
        curl -sL -m 120 "https://get.helm.sh/helm-$HV-linux-$ARCH.tar.gz" | tar -xz -C "$TMPD" --strip-components=1 "linux-$ARCH/helm" \
                && "$TMPD/helm" version >/dev/null 2>&1 || fail "Cannot download helm"
        PATH=$TMPD:$PATH
fi

if ! KERR=$(kubectl get nodes -o wide 2>&1); then
        echo "$KERR" | grep -v memcache.go | head -3 | sed 's/^/         /'
        grep -qiE 'system:unauthenticated|Unauthorized|token' <<<"$KERR" && \
                info "-> Kubeconfig token expired. Rancher UI > Cluster Management > cluster > Download KubeConfig"
        fail "Cannot reach the cluster with $KUBECONFIG"
fi
echo "$KERR"
K8SVER=$(kubectl get nodes --no-headers | awk 'NR==1{print $5}')

#############################################################
step "2. Detect Prometheus"
#############################################################
PLINE=$(kubectl get prometheus -A --no-headers 2>/dev/null | head -1)
[[ -n "$PLINE" ]] || fail "No Prometheus in this cluster -> install monitoring first"
PNS=$(awk '{print $1}' <<<"$PLINE"); PNAME=$(awk '{print $2}' <<<"$PLINE")
ok "Prometheus $PNS/$PNAME"
pjp() { kubectl get prometheus -n "$PNS" "$PNAME" -o jsonpath="$1" 2>/dev/null; }

SM_SEL=$(pjp '{.spec.serviceMonitorSelector}')
SM_REL=$(pjp '{.spec.serviceMonitorSelector.matchLabels.release}')
info "serviceMonitorSelector = ${SM_SEL:-<nil>}"
[[ -z "$SM_SEL" ]] && fail "serviceMonitorSelector is nil -> Prometheus ignores ServiceMonitors. Set serviceMonitorSelectorNilUsesHelmValues: false first."
if [[ -n "$SM_REL" ]]; then SM_LABEL=$SM_REL
else case "$PNAME" in
        rancher-monitoring-*)    SM_LABEL=rancher-monitoring ;;
        kube-prometheus-stack-*) SM_LABEL=kube-prometheus-stack ;;
        *)                       SM_LABEL=${PNAME%-prometheus} ;;
esac; fi

# existing x509 exporter?
SKIP_HELM=""
EXIST_X509=$(kubectl get pod -A --no-headers 2>/dev/null | grep -i x509)
if [[ -n "$EXIST_X509" ]]; then
        ok "x509 exporter already running:"
        echo "$EXIST_X509" | awk '{printf "           %s/%s  %s %s\n",$1,$2,$3,$4}'
        ask KEEP_X509 "Keep it and skip the helm install? y/n" "y"
        [[ "$KEEP_X509" =~ ^[Yy]$ ]] && SKIP_HELM=y
fi

# remoteWrite entries to OLS
NRW=$(pjp '{range .spec.remoteWrite[*]}{.url}{"\n"}{end}' | grep -c .)
CERT_OK=""; FIRST_OLS=""; EXIST_NAMES=()
for ((i=0; i<NRW; i++)); do
        n=$(pjp "{.spec.remoteWrite[$i].name}"); EXIST_NAMES+=("$n")
        u=$(pjp "{.spec.remoteWrite[$i].url}")
        [[ "$u" == *metrics-gateway.olsxops.com* ]] || { info "remoteWrite[$i] $n -> $u (kept)"; continue; }
        [[ -z "$FIRST_OLS" ]] && FIRST_OLS=$i
        t=$(pjp "{.spec.remoteWrite[$i].headers.X-Scope-OrgID}")
        k=$(pjp "{.spec.remoteWrite[$i].writeRelabelConfigs[?(@.action==\"keep\")].regex}")
        info "remoteWrite[$i] $n tenant=${t:-none} keep=${k:-<all>}"
        [[ "$t" == "$CERT_TENANT" && ( -z "$k" || "$k" == *x509_* ) ]] && CERT_OK=$i
done
DEF_CLUSTER=""; DEF_PIP=""
if [[ -n "$FIRST_OLS" ]]; then
        DEF_CLUSTER=$(pjp "{.spec.remoteWrite[$FIRST_OLS].writeRelabelConfigs[?(@.targetLabel==\"cluster\")].replacement}" | awk '{print $1}')
        DEF_PIP=$(pjp "{.spec.remoteWrite[$FIRST_OLS].writeRelabelConfigs[?(@.targetLabel==\"public_ip\")].replacement}" | awk '{print $1}')
fi
[[ -z "$DEF_CLUSTER" ]] && DEF_CLUSTER=$(kubectl get nodes --no-headers | awk 'NR==1{print $1}' | sed -E 's/-(master|worker|control|cp|node)[^-]*(-[0-9]+)?$//I' | tr 'A-Z' 'a-z')
if [[ -n "$CERT_OK" ]]; then ok "remoteWrite[$CERT_OK] already sends x509_ to tenant $CERT_TENANT"
else warn "No remoteWrite sends x509_ to tenant $CERT_TENANT (Certificate Monitoring) -> will add one"; fi

[[ -n "$SKIP_HELM" && -n "$CERT_OK" ]] && { ok "Nothing to do - exporter and $CERT_TENANT remoteWrite already exist"; exit 0; }

#############################################################
step "3. Settings"
#############################################################
# cert directories on the control-plane nodes
case "$K8SVER" in
        *rke2*) DEF_DIRS="/var/lib/rancher/rke2/server/tls/ /var/lib/rancher/rke2/server/tls/kube-scheduler/ /var/lib/rancher/rke2/server/tls/kube-controller-manager/" ;;
        *k3s*)  DEF_DIRS="/var/lib/rancher/k3s/server/tls/" ;;
        *)      DEF_DIRS="/etc/kubernetes/ssl/ /etc/kubernetes/pki/" ;;
esac
CP_LABEL=""
for l in node-role.kubernetes.io/control-plane node-role.kubernetes.io/controlplane node-role.kubernetes.io/master; do
        [[ -n "$(kubectl get nodes -l "$l" --no-headers 2>/dev/null)" ]] && { CP_LABEL=$l; break; }
done
CP_VAL=""
[[ -n "$CP_LABEL" ]] && CP_VAL=$(kubectl get nodes -l "$CP_LABEL" --no-headers --show-labels 2>/dev/null | grep -o "$CP_LABEL=[^, ]*" | head -1 | cut -d= -f2)

echo "  ---------------------------------------------------------------------------------"
echo "  1) cluster    : label cluster= in Certificate Monitoring   (found: ${DEF_CLUSTER:-none})"
echo "  2) public_ip  : customer public IP, label public_ip=       (found: ${DEF_PIP:-none})"
[[ -z "$SKIP_HELM" ]] && \
echo "  3) cert dirs  : directories with .crt files on control-plane nodes"
echo "  ---------------------------------------------------------------------------------"
while :; do
        ask CLUSTER_NAME "1) cluster" "$DEF_CLUSTER"
        [[ "$CLUSTER_NAME" =~ ^[A-Za-z0-9._-]+$ ]] && break
        echo -e "  ${RED}Use letters, numbers, . _ - only${NC}"; CLUSTER_NAME=""
done
if [[ -z "$CERT_OK" ]]; then
        while :; do
                ask PUBLIC_IP "2) public_ip" "$DEF_PIP"
                [[ "$PUBLIC_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && break
                echo -e "  ${RED}Enter an IPv4 address${NC}"; PUBLIC_IP=""
        done
        RW_NAME="$CLUSTER_NAME-cert"
        for n in "${EXIST_NAMES[@]}"; do [[ "$n" == "$RW_NAME" ]] && RW_NAME="$CLUSTER_NAME-cert-2"; done
fi
[[ -z "$SKIP_HELM" ]] && ask CERT_DIRS "3) cert dirs (space separated)" "$DEF_DIRS"

NEED_SECRET=""
if [[ -z "$CERT_OK" ]] && ! kubectl get secret -n "$PNS" "$SECRET" >/dev/null 2>&1; then
        warn "Secret $PNS/$SECRET not found -> will create it (manual step 'Create Secret')"
        ask MIMIR_USER "Mimir username" "mimiradmin"
        while [[ -z "$MIMIR_PASS" ]]; do read -r -s -p "  Mimir password (hidden, see manual 'Create Secret'): " MIMIR_PASS; echo ""; done
        NEED_SECRET=1
fi

#############################################################
step "4. Plan"
#############################################################
info "Cluster      : $CLUSTER_NAME  (k8s $K8SVER)"
if [[ -z "$SKIP_HELM" ]]; then
        info "Helm         : $X509_RELEASE (enix/x509-certificate-exporter ${X509_CHART_VERSION:-latest}) in ns $PNS"
        info "Runs on      : nodes with ${CP_LABEL:-<all nodes>}${CP_VAL:+=$CP_VAL}"
        info "Cert dirs    : $CERT_DIRS"
        info "ServiceMonitor label release=$SM_LABEL"
else
        info "x509 exporter: existing one kept"
fi
[[ -n "$NEED_SECRET" ]] && info "Secret       : create $PNS/$SECRET (username=$MIMIR_USER)"
if [[ -z "$CERT_OK" ]]; then
        info "remoteWrite  : add '$RW_NAME' tenant=$CERT_TENANT keep=x509_.* cluster=$CLUSTER_NAME public_ip=$PUBLIC_IP"
fi
echo ""
if [[ "$ASSUME_YES" != y ]]; then
        read -r -p "  Apply now? [y/N]: " GO
        [[ "$GO" =~ ^[Yy]$ ]] || { echo "  Cancelled - nothing changed."; exit 0; }
fi
mkdir -p "$WORKDIR"

#############################################################
if [[ -z "$SKIP_HELM" ]]; then
step "5. Helm install x509-certificate-exporter"
#############################################################
{
echo "secretsExporter:"
echo "  enabled: false"
echo "hostPathsExporter:"
if [[ -n "$CP_LABEL" ]]; then
echo "  nodeSelector:"
echo "    $CP_LABEL: \"$CP_VAL\""
fi
echo "  tolerations:"
echo "    - operator: Exists"
echo "  daemonSets:"
echo "    node:"
echo "      watchDirectories:"
for d in $CERT_DIRS; do echo "        - $d"; done
echo "prometheusServiceMonitor:"
echo "  create: true"
echo "  extraLabels:"
echo "    release: $SM_LABEL"
echo "prometheusRules:"
echo "  create: false"
} > "$WORKDIR/x509.values.yaml"
ok "Wrote $WORKDIR/x509.values.yaml"
sed 's/^/         /' "$WORKDIR/x509.values.yaml"

helm repo add enix https://charts.enix.io >/dev/null 2>&1
helm repo update enix >/dev/null 2>&1 || helm repo update >/dev/null 2>&1 || fail "helm repo update failed (no internet?)"
VER_ARG=(); [[ -n "$X509_CHART_VERSION" ]] && VER_ARG=(--version "$X509_CHART_VERSION")
helm upgrade --install "$X509_RELEASE" enix/x509-certificate-exporter -n "$PNS" \
        -f "$WORKDIR/x509.values.yaml" "${VER_ARG[@]}" --wait --timeout 5m \
        || fail "helm install failed (check: kubectl get pod -n $PNS | grep x509)"
kubectl get pod -n "$PNS" -l "app.kubernetes.io/instance=$X509_RELEASE" -o wide
kubectl get servicemonitor -n "$PNS" -l "app.kubernetes.io/instance=$X509_RELEASE" --show-labels
fi

#############################################################
step "6. remoteWrite to OLS Observe (tenant $CERT_TENANT)"
#############################################################
PATCHED=""
if [[ -n "$CERT_OK" ]]; then
        ok "Already exists (remoteWrite[$CERT_OK]) - not changed"
else
        kubectl get prometheus -n "$PNS" "$PNAME" -o yaml > "$WORKDIR/prometheus-$PNAME.$(date +%Y%m%d-%H%M%S).backup.yaml"
        if [[ -n "$NEED_SECRET" ]]; then
                kubectl create secret generic "$SECRET" -n "$PNS" \
                        --from-env-file=<(printf 'username=%s\npassword=%s\n' "$MIMIR_USER" "$MIMIR_PASS") \
                        || fail "Cannot create secret $PNS/$SECRET"
                unset MIMIR_PASS
                ok "Secret $PNS/$SECRET created"
        fi
        ENTRY=$(printf '{"url":"%s","name":"%s","basicAuth":{"username":{"name":"%s","key":"username"},"password":{"name":"%s","key":"password"}},"headers":{"X-Scope-OrgID":"%s"},"writeRelabelConfigs":[{"action":"keep","sourceLabels":["__name__"],"regex":"x509_.*"},{"action":"replace","replacement":"%s","targetLabel":"cluster"},{"action":"replace","replacement":"%s","targetLabel":"public_ip"}]}' \
                "$RW_URL" "$RW_NAME" "$SECRET" "$SECRET" "$CERT_TENANT" "$CLUSTER_NAME" "$PUBLIC_IP")
        if [[ $NRW -eq 0 ]]; then PATCH="[{\"op\":\"add\",\"path\":\"/spec/remoteWrite\",\"value\":[$ENTRY]}]"
        else PATCH="[{\"op\":\"add\",\"path\":\"/spec/remoteWrite/-\",\"value\":$ENTRY}]"; fi
        kubectl patch prometheus -n "$PNS" "$PNAME" --type=json -p="$PATCH" || fail "kubectl patch failed"
        ok "remoteWrite '$RW_NAME' added (backup in $WORKDIR)"
        PATCHED=1
        case "$PNAME" in rancher-monitoring-*|kube-prometheus-stack-*)
                warn "Prometheus is Helm-managed: also put this remoteWrite in the app values (Rancher > Apps > ${PNAME%-prometheus} > Edit YAML)" ;;
        esac
fi

#############################################################
step "7. Verify (up to 4 min)"
#############################################################
PPOD=$(kubectl get pod -n "$PNS" -l "operator.prometheus.io/name=$PNAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -z "$PPOD" ]] && PPOD="prometheus-$PNAME-0"
pval() { kubectl exec -n "$PNS" "$PPOD" -c prometheus -- promtool query instant http://localhost:9090 "$1" 2>/dev/null \
        | grep ' => ' | awk -F' => ' 'NR==1{split($2,a," "); print a[1]}'; }
if [[ "$(pval 'vector(1)')" != 1 ]]; then
        warn "Cannot query Prometheus - check later with observe-check.sh"
else
        N=""; S=""
        for i in $(seq 1 24); do
                N=$(pval 'count(x509_cert_not_after)')
                [[ -n "$PATCHED" ]] && S=$(pval "sum(increase(prometheus_remote_storage_samples_total{remote_name=\"$RW_NAME\"}[2m]))")
                if [[ -n "$N" ]] && { [[ -z "$PATCHED" ]] || { [[ -n "$S" ]] && awk "BEGIN{exit !($S > 0)}"; }; }; then break; fi
                printf "\r         waiting for scrape / remoteWrite... %ss " "$((i*10))"
                sleep 10
        done
        echo ""
        if [[ -n "$N" ]]; then ok "Prometheus has $N certificate(s) (x509_cert_not_after)"
        else warn "No x509 metrics yet: kubectl get pod,servicemonitor -n $PNS | grep x509 ; kubectl logs -n $PNS -l app.kubernetes.io/instance=$X509_RELEASE --tail=20"; fi
        if [[ -n "$PATCHED" ]]; then
                if [[ -n "$S" ]] && awk "BEGIN{exit !($S > 0)}"; then ok "'$RW_NAME' is sending to Observe"
                else warn "'$RW_NAME' not sending yet (Prometheus reload 1-3 min; if it stays 0 see observe-check.sh)"; fi
        fi
fi

echo ""
echo -e "${GREEN}${bold}Done.${normal}${NC} Cert monitoring for $CLUSTER_NAME. Files: $WORKDIR"
echo "  Check   : bash <(curl -s https://raw.githubusercontent.com/Hayato360/Script/refs/heads/main/observe-check.sh)"
echo "  Grafana : Certificate Monitoring -> wait 2-3 min, reload page (F5)"
echo ""
