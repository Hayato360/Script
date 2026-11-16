#!/bin/bash
#############################################################################
# Install Blackbox exporter + Probes (add-on for clusters that already have Cert)
#
# Needs  : Prometheus already installed (rancher-monitoring or kube-prometheus-stack)
#          and remoteWrite to OLS Observe already set (keep regex with probe_)
# Installs:
#   1. Helm chart prometheus-community/prometheus-blackbox-exporter  (ns blackbox)
#   2. Probe 01-coredns         (dns_udp  -> cluster DNS service)
#   3. Probe 02-rancher-health  (http_2xx -> <Rancher URL>/healthz)
#   (no TCP probe - 03-rancher-tcp-probe is skipped on purpose)
#
# Run on : a master node or the Rancher VM, as root, with kubeconfig of the cluster
# Usage  : bash <(curl -s https://raw.githubusercontent.com/Hayato360/Script/refs/heads/main/blackbox-install.sh)
#
# Optional env (otherwise detected / asked):
#   You fill (asked): CLUSTER_NAME=mycluster  RANCHER_URL=https://rancher.customer.com  DNS_TARGET=<svc>:53|skip
#   KUBECONFIG=/root/.kube/<cluster>.yaml
#   BB_NS=blackbox  BB_RELEASE=blackbox-exporter  BB_CHART_VERSION=<chart version>
#   PROBE_NS=<ns>  PROBE_RELEASE_LABEL=<release label>  WORKDIR=/root/blackbox  ASSUME_YES=y
#############################################################################

PATH=$PATH:/var/lib/rancher/rke2/bin:/usr/local/bin

bold=$(tput bold 2>/dev/null)
normal=$(tput sgr0 2>/dev/null)
RED='\e[0;31m'
GREEN='\e[0;32m'
YELLOW='\e[0;33m'
CYAN='\e[0;36m'
NC='\e[0m'

BB_NS=${BB_NS:-blackbox}
BB_RELEASE=${BB_RELEASE:-blackbox-exporter}
WORKDIR=${WORKDIR:-/root/blackbox}

step() { echo ""; echo -e "${GREEN}${bold}==> $*${normal}${NC}"; }
ok()   { echo -e "  ${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }
info() { echo -e "         $*"; }
fail() { echo -e "  ${RED}[ERROR]${NC} $*"; exit 1; }

# ask VAR "question" "default" : keep env value if set, otherwise prompt with default
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
tmpdir() { [[ -z "$TMPD" ]] && TMPD=$(mktemp -d /tmp/blackbox-install.XXXXXX); }
ARCH=$(uname -m); [[ "$ARCH" == aarch64 ]] && ARCH=arm64 || ARCH=amd64

echo ""
echo -e "${RED}########################################################################################${NC}"
echo -e "  Install ${bold}Blackbox exporter + Probes${normal} (CoreDNS + Rancher health, no TCP probe)"
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

# kubectl (temp download if missing)
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

# helm (temp download if missing)
if ! command -v helm >/dev/null 2>&1; then
        warn "helm not found -> downloading a temporary helm to /tmp (removed at exit)"
        tmpdir
        HV=${HELM_VERSION:-v3.17.3}   # pinned Helm 3 (Helm 4 changed flags)
        curl -sL -m 120 "https://get.helm.sh/helm-$HV-linux-$ARCH.tar.gz" | tar -xz -C "$TMPD" --strip-components=1 "linux-$ARCH/helm" \
                && "$TMPD/helm" version >/dev/null 2>&1 || fail "Cannot download helm"
        PATH=$TMPD:$PATH
fi
ok "kubectl + helm ready ($(helm version --short 2>/dev/null))"

if ! KERR=$(kubectl get nodes -o wide 2>&1); then
        echo "$KERR" | grep -v memcache.go | head -3 | sed 's/^/         /'
        if grep -qiE 'system:unauthenticated|Unauthorized|token' <<<"$KERR"; then
                info "-> The kubeconfig token is expired/deleted (Rancher kubeconfig tokens have a TTL)."
                info "   Rancher UI > Cluster Management > this cluster > (3 dots) Download KubeConfig"
                info "   save as /root/.kube/<cluster>.yaml, then run:"
                info "   KUBECONFIG=/root/.kube/<cluster>.yaml bash <(curl -s https://raw.githubusercontent.com/Hayato360/Script/refs/heads/main/blackbox-install.sh)"
                info "   (or run on an RKE2 master node: it uses /etc/rancher/rke2/rke2.yaml)"
        fi
        fail "Cannot reach the cluster with $KUBECONFIG"
fi
echo "$KERR"
K8SVER=$(kubectl get nodes --no-headers | awk 'NR==1{print $5}')

#############################################################
step "2. Detect Prometheus / Cert setup"
#############################################################
kubectl get crd probes.monitoring.coreos.com >/dev/null 2>&1 || fail "No Probe CRD -> Prometheus Operator not installed. Install monitoring (Cert) first."
PLINE=$(kubectl get prometheus -A --no-headers 2>/dev/null | head -1)
[[ -n "$PLINE" ]] || fail "No Prometheus object -> install monitoring (Cert) first."
PNS=$(awk '{print $1}' <<<"$PLINE"); PNAME=$(awk '{print $2}' <<<"$PLINE")
ok "Prometheus $PNS/$PNAME"

pjp() { kubectl get prometheus -n "$PNS" "$PNAME" -o jsonpath="$1" 2>/dev/null; }
PSEL_RAW=$(pjp '{.spec.probeSelector}')
PSEL_REL=$(pjp '{.spec.probeSelector.matchLabels.release}')
PNSSEL_RAW=$(pjp '{.spec.probeNamespaceSelector}')
info "probeSelector          = ${PSEL_RAW:-<nil>}"
info "probeNamespaceSelector = ${PNSSEL_RAW:-<nil> (own namespace $PNS only)}"
[[ -z "$PSEL_RAW" ]] && fail "Prometheus probeSelector is nil -> it ignores all Probes. Set probeSelectorNilUsesHelmValues: false (or probeSelector: {}) in monitoring values first."

# release label for Probes
if [[ -z "$PROBE_RELEASE_LABEL" ]]; then
        if [[ -n "$PSEL_REL" ]]; then PROBE_RELEASE_LABEL=$PSEL_REL
        else case "$PNAME" in
                rancher-monitoring-*)    PROBE_RELEASE_LABEL=rancher-monitoring ;;
                kube-prometheus-stack-*) PROBE_RELEASE_LABEL=kube-prometheus-stack ;;
                *)                       PROBE_RELEASE_LABEL=${PNAME%-prometheus} ;;
        esac; fi
fi
# namespace for Probes: nil namespace selector = Prometheus only sees its own namespace
if [[ -z "$PROBE_NS" ]]; then
        if [[ -z "$PNSSEL_RAW" ]]; then PROBE_NS=$PNS; else PROBE_NS=$BB_NS; fi
fi
OTHER_SEL=$(pjp '{.spec.probeSelector.matchLabels}' | grep -o '"[^"]*":' | tr -d '":' | grep -vx release)
[[ -n "$OTHER_SEL" ]] && warn "probeSelector also needs labels: $OTHER_SEL (not added by this script - check)"

# remoteWrite from Cert setup
RW_URL=$(pjp '{.spec.remoteWrite[*].url}')
RW_KEEP=$(pjp '{.spec.remoteWrite[*].writeRelabelConfigs[?(@.action=="keep")].regex}')
RW_CLUSTER=$(pjp '{.spec.remoteWrite[*].writeRelabelConfigs[?(@.targetLabel=="cluster")].replacement}' | awk '{print $1}')
if [[ -z "$RW_URL" ]]; then
        warn "No remoteWrite on Prometheus -> probe results stay local only (Cert setup not done?)"
else
        ok "remoteWrite: $RW_URL"
        if [[ -n "$RW_KEEP" && "$RW_KEEP" != *probe_* ]]; then
                warn "remoteWrite keep regex is '$RW_KEEP' -> probe_* is NOT sent to Observe"
                info "Add probe_ to it later, e.g. regex: \"x509_.*|probe_.*\" (this script does not edit Prometheus)"
        else
                ok "keep regex includes probe_ (${RW_KEEP:-no filter})"
        fi
fi

EXIST=$(kubectl get deploy -A --no-headers 2>/dev/null | grep -i blackbox | grep -v "^$BB_NS[[:space:]]*$BB_RELEASE-")
[[ -n "$EXIST" ]] && { warn "Another blackbox exporter already exists:"; echo "$EXIST" | sed 's/^/           /'; }

#############################################################
step "3. Settings"
#############################################################
# Rancher URL: from cattle-cluster-agent (downstream) or server-url setting (local cluster)
DEF_URL=$(kubectl get deploy -n cattle-system cattle-cluster-agent -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CATTLE_SERVER")].value}' 2>/dev/null)
[[ -z "$DEF_URL" ]] && DEF_URL=$(kubectl get settings.management.cattle.io server-url -o jsonpath='{.value}' 2>/dev/null)
DEF_URL=${DEF_URL%/}

# cluster DNS service
DNS_SVC=$(kubectl get svc -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -z "$DNS_SVC" ]] && DNS_SVC=$(kubectl get svc -n kube-system --no-headers 2>/dev/null | awk '$1 ~ /dns/ && $5 ~ /53\//{print $1; exit}')
DNS_DOMAIN=cluster.local

DEF_CLUSTER=${RW_CLUSTER:-$(kubectl get nodes --no-headers | awk 'NR==1{print $1}' | sed -E 's/-(master|worker|control|cp|node)[^-]*(-[0-9]+)?$//I')}

echo ""
echo -e "  ${YELLOW}${bold}Fields YOU fill (customer-specific)${normal}${NC}  - press Enter to accept [default]"
echo "  ---------------------------------------------------------------------------------"
echo "  1) Cluster name : label cluster= on the probes, shown in Grafana (no spaces)"
echo "                    should match the Cert remoteWrite cluster label${RW_CLUSTER:+ (found: $RW_CLUSTER)}"
echo "                    e.g. ranchy, urbanway, LppRiceMill, dentcot"
echo "  2) Rancher URL  : Rancher server of this customer, probed as <URL>/healthz"
echo "                    e.g. https://ranchy.openlandscape.cloud${DEF_URL:+   (found: $DEF_URL)}"
echo "  3) DNS target   : cluster DNS service:port for the CoreDNS probe"
echo "                    RKE2 = rke2-coredns-rke2-coredns..., RKE1 = kube-dns...${DNS_SVC:+   (found: $DNS_SVC)}"
echo "  ---------------------------------------------------------------------------------"

while :; do
        ask CLUSTER_NAME "1) Cluster name" "$DEF_CLUSTER"
        [[ -n "$CLUSTER_NAME" && "$CLUSTER_NAME" != *[[:space:]]* ]] && break
        echo -e "  ${RED}Cluster name must not be empty or contain spaces${NC}"; CLUSTER_NAME=""
done
[[ -n "$RW_CLUSTER" && "$CLUSTER_NAME" != "$RW_CLUSTER" ]] && warn "Differs from Cert remoteWrite label '$RW_CLUSTER' (remoteWrite will overwrite it to '$RW_CLUSTER' in Observe)"

while :; do
        ask RANCHER_URL "2) Rancher URL" "$DEF_URL"
        RANCHER_URL=${RANCHER_URL%/}; RANCHER_URL=${RANCHER_URL%/healthz}
        [[ -n "$RANCHER_URL" && "$RANCHER_URL" != *[[:space:]]* ]] && break
        echo -e "  ${RED}Rancher URL is required (e.g. https://rancher.customer.com)${NC}"; RANCHER_URL=""
done
[[ "$RANCHER_URL" == http* ]] || RANCHER_URL="https://$RANCHER_URL"
CODE=$(curl -sk -o /dev/null -m 8 -w '%{http_code}' "$RANCHER_URL/healthz" 2>/dev/null)
if [[ "$CODE" == 200 ]]; then ok "$RANCHER_URL/healthz -> 200 from this host"
else warn "$RANCHER_URL/healthz -> HTTP ${CODE:-000} from this host (check the URL; the probe runs from inside the cluster)"; fi

DEF_DNS=""; [[ -n "$DNS_SVC" ]] && DEF_DNS="$DNS_SVC.kube-system.svc.$DNS_DOMAIN:53"
ask DNS_TARGET "3) DNS target (type 'skip' for no DNS probe)" "${DEF_DNS:-skip}"
[[ "$DNS_TARGET" == skip ]] && DNS_TARGET=""
[[ -n "$DNS_TARGET" && "$DNS_TARGET" != *:* ]] && DNS_TARGET="$DNS_TARGET:53"

BB_SVC="$BB_RELEASE-prometheus-blackbox-exporter"
[[ "$BB_RELEASE" == *prometheus-blackbox-exporter* ]] && BB_SVC=$BB_RELEASE
PROBER="$BB_SVC.$BB_NS.svc:9115"

echo ""
echo -e "  ${bold}Plan${normal}   (you filled: cluster, Rancher URL, DNS target - the rest is auto-detected)"
info "Cluster           : $CLUSTER_NAME   (k8s $K8SVER)"
info "Helm release      : $BB_RELEASE in ns $BB_NS  (chart ${BB_CHART_VERSION:-latest})"
info "Prober URL        : $PROBER"
info "Probes namespace  : $PROBE_NS   label release=$PROBE_RELEASE_LABEL"
if [[ -n "$DNS_TARGET" ]]; then
        info "01-coredns        : dns_udp  -> $DNS_TARGET"
else
        warn "01-coredns        : skipped (no DNS target)"
fi
info "02-rancher-health : http_2xx -> $RANCHER_URL/healthz"
info "03-rancher-tcp    : skipped"
info "Files saved in    : $WORKDIR"
echo ""
if [[ "$ASSUME_YES" != y ]]; then
        read -r -p "  Install now? [y/N]: " GO
        [[ "$GO" =~ ^[Yy]$ ]] || { echo "  Cancelled - nothing changed."; exit 0; }
fi

#############################################################
step "4. Helm install blackbox exporter"
#############################################################
mkdir -p "$WORKDIR"
cat > "$WORKDIR/blackbox.values.yaml" <<'EOF'
config:
  modules:
    http_2xx:
      prober: http
      timeout: 10s
      http:
        method: GET
        follow_redirects: true
        preferred_ip_protocol: ip4
        tls_config:
          insecure_skip_verify: true
    dns_udp:
      prober: dns
      timeout: 5s
      dns:
        transport_protocol: udp
        preferred_ip_protocol: ip4
        query_name: kubernetes.default.svc.cluster.local
        query_type: A
        valid_rcodes:
          - NOERROR
    tcp_connect:
      prober: tcp
      timeout: 5s
      tcp:
        preferred_ip_protocol: ip4

resources:
  requests:
    cpu: 10m
    memory: 32Mi
  limits:
    cpu: 100m
    memory: 128Mi

serviceMonitor:
  selfMonitor:
    enabled: false
EOF
ok "Wrote $WORKDIR/blackbox.values.yaml"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1
helm repo update prometheus-community >/dev/null 2>&1 || helm repo update >/dev/null 2>&1 || fail "helm repo update failed (no internet?)"

VER_ARG=()
[[ -n "$BB_CHART_VERSION" ]] && VER_ARG=(--version "$BB_CHART_VERSION")
helm upgrade --install "$BB_RELEASE" prometheus-community/prometheus-blackbox-exporter \
        -n "$BB_NS" --create-namespace \
        -f "$WORKDIR/blackbox.values.yaml" "${VER_ARG[@]}" \
        --wait --timeout 5m \
        || fail "helm install failed. Old k8s ($K8SVER)? retry with BB_CHART_VERSION=<older chart> (helm search repo prometheus-community/prometheus-blackbox-exporter --versions)"

kubectl get svc -n "$BB_NS" "$BB_SVC" >/dev/null 2>&1 || {
        BB_SVC=$(kubectl get svc -n "$BB_NS" -l "app.kubernetes.io/instance=$BB_RELEASE" -o jsonpath='{.items[0].metadata.name}')
        PROBER="$BB_SVC.$BB_NS.svc:9115"
        warn "Service name differs, using $PROBER"
}
kubectl get pod -n "$BB_NS" -l "app.kubernetes.io/instance=$BB_RELEASE"
ok "Blackbox exporter running, prober $PROBER"

#############################################################
step "5. Apply Probes"
#############################################################
probe_yaml() { # name module target service
cat <<EOF
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: $1
  namespace: $PROBE_NS
  labels:
    release: $PROBE_RELEASE_LABEL
spec:
  interval: 30s
  scrapeTimeout: 10s
  module: $2
  prober:
    url: $PROBER
  targets:
    staticConfig:
      static:
        - $3
      labels:
        cluster: $CLUSTER_NAME
        service: $4
EOF
}

if [[ -n "$DNS_TARGET" ]]; then
        probe_yaml coredns dns_udp "$DNS_TARGET" coredns > "$WORKDIR/01-coredns-probe.yaml"
        kubectl apply -f "$WORKDIR/01-coredns-probe.yaml" || fail "apply 01-coredns-probe.yaml failed"
fi
probe_yaml rancher-health http_2xx "$RANCHER_URL/healthz" monitoring > "$WORKDIR/02-rancher-health-probe.yaml"
kubectl apply -f "$WORKDIR/02-rancher-health-probe.yaml" || fail "apply 02-rancher-health-probe.yaml failed"
kubectl get probes.monitoring.coreos.com -n "$PROBE_NS"

#############################################################
step "6. Verify (waiting up to 2 min for first probe results)"
#############################################################
PPOD=$(kubectl get pod -n "$PNS" -l "operator.prometheus.io/name=$PNAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -z "$PPOD" ]] && PPOD="prometheus-$PNAME-0"
promq() { kubectl exec -n "$PNS" "$PPOD" -c prometheus -- promtool query instant http://localhost:9090 "$1" 2>/dev/null; }

RESULT=""; CANQ=0; INCONF=0
[[ "$(promq 'vector(1)' | grep ' => ' | awk -F' => ' 'NR==1{split($2,a," "); print a[1]}')" == 1 ]] && CANQ=1
[[ $CANQ -eq 0 ]] && warn "Cannot query Prometheus with kubectl exec (permission?) - only checking config"
# did the operator put the Probe jobs into the Prometheus config?
inconf() {
        kubectl get secret -n "$PNS" "prometheus-$PNAME" -o jsonpath='{.data.prometheus\.yaml\.gz}' 2>/dev/null \
                | base64 -d 2>/dev/null | gunzip 2>/dev/null | grep -c "job_name: probe/$PROBE_NS/"
}
for i in $(seq 1 18); do
        [[ $INCONF -eq 0 && "$(inconf)" -gt 0 ]] 2>/dev/null && { INCONF=1; ok "Probe jobs are in Prometheus config (selected OK)"; }
        if [[ $CANQ -eq 1 ]]; then
                RESULT=$(promq 'probe_success{job=~"probe/.*/(coredns|rancher-health)"}' | grep ' => ' | sed -E 's/ @\[.*$//')
                [[ -n "$RESULT" ]] && break
        elif [[ $INCONF -eq 1 ]]; then
                break
        fi
        sleep 10
done
if [[ -z "$RESULT" ]]; then
        if [[ $INCONF -eq 0 ]]; then
                warn "Probe jobs NOT in Prometheus config after 3 min -> Prometheus does not select the Probes"
                info "check: kubectl get prometheus -n $PNS $PNAME -o yaml | grep -A3 -i probe"
                info "Probe labels: kubectl get probes -n $PROBE_NS --show-labels"
        elif [[ $CANQ -eq 1 ]]; then
                warn "Probes are configured but no probe_success yet - check scrape errors:"
                info "kubectl exec -n $PNS $PPOD -c prometheus -- promtool query instant http://localhost:9090 'up{job=~\"probe/.*\"}'"
        fi
        info "Re-check in a few minutes: bash <(curl -s https://raw.githubusercontent.com/Hayato360/Script/refs/heads/main/observe-check.sh)"
else
        while IFS= read -r l; do
                job=$(grep -o 'job="[^"]*"' <<<"$l" | cut -d'"' -f2)
                inst=$(grep -o 'instance="[^"]*"' <<<"$l" | cut -d'"' -f2)
                val=${l##* => }
                if [[ "$val" == 1 ]]; then ok "UP    $job  $inst"; else warn "DOWN  $job  $inst (exporter works, target not reachable from pod)"; fi
        done <<<"$RESULT"
fi

echo ""
echo -e "${GREEN}${bold}Done.${normal}${NC} Blackbox installed on $CLUSTER_NAME. Files: $WORKDIR"
echo "  Full check: bash <(curl -s https://raw.githubusercontent.com/Hayato360/Script/refs/heads/main/observe-check.sh)"
echo ""
