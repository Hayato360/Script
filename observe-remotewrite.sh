#!/bin/bash
#############################################################################
# Add k8s cluster to OLS Observe  -  Prometheus remoteWrite (manual step "edit by kubectl")
#
# Adds this block to the Prometheus object (same as kubectl edit + paste above status:)
#
#   remoteWrite:
#     - url: https://metrics-gateway.olsxops.com/api/v1/push
#       name: <NAME>                          <- asked
#       basicAuth:  username/password from secret mimir-auth
#       headers:
#         "X-Scope-OrgID": rancher-health
#       writeRelabelConfigs:
#         - action: keep
#           sourceLabels: [__name__]
#           regex: "x509_.*|probe_.*"
#         - action: replace
#           replacement: <CLUSTER>            <- asked
#           targetLabel: cluster
#         - action: replace
#           replacement: "<PUBLIC_IP>"        <- asked
#           targetLabel: public_ip
#
# Existing remoteWrite entries (e.g. INET o11y-metrics) are kept, the new one is appended.
# Uses kubectl patch (no editor), saves a backup first, then checks that it is sending.
#
# Run on : a master node or the Rancher VM, as root, with kubeconfig of the cluster
# Usage  : bash <(curl -s https://raw.githubusercontent.com/Hayato360/Script/refs/heads/main/observe-remotewrite.sh)
#
# Optional env (otherwise asked):
#   RW_NAME=ranchy  CLUSTER_NAME=urbanway  PUBLIC_IP=203.150.145.39
#   KUBECONFIG=/root/.kube/<cluster>.yaml  WORKDIR=/root/observe  ASSUME_YES=y
#############################################################################

PATH=$PATH:/var/lib/rancher/rke2/bin:/usr/local/bin
RW_URL=https://metrics-gateway.olsxops.com/api/v1/push
RW_TENANT=rancher-health
RW_REGEX='x509_.*|probe_.*'
SECRET=mimir-auth
WORKDIR=${WORKDIR:-/root/observe}

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

echo ""
echo -e "${RED}########################################################################################${NC}"
echo -e "  ${bold}Add k8s cluster to OLS Observe${normal} - Prometheus remoteWrite (tenant $RW_TENANT)"
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
                TMPD=$(mktemp -d /tmp/observe-rw.XXXXXX)
                ARCH=$(uname -m); [[ "$ARCH" == aarch64 ]] && ARCH=arm64 || ARCH=amd64
                KV=$(curl -sL -m 15 https://dl.k8s.io/release/stable.txt)
                curl -sL -m 120 -o "$TMPD/kubectl" "https://dl.k8s.io/release/$KV/bin/linux/$ARCH/kubectl" && chmod +x "$TMPD/kubectl" \
                        && "$TMPD/kubectl" version --client >/dev/null 2>&1 || fail "Cannot download kubectl"
                PATH=$TMPD:$PATH
        fi
fi

if ! KERR=$(kubectl get nodes 2>&1); then
        echo "$KERR" | grep -v memcache.go | head -3 | sed 's/^/         /'
        if grep -qiE 'system:unauthenticated|Unauthorized|token' <<<"$KERR"; then
                info "-> Kubeconfig token expired/deleted. Rancher UI > Cluster Management > cluster > Download KubeConfig,"
                info "   save as /root/.kube/<cluster>.yaml and run with KUBECONFIG=/root/.kube/<cluster>.yaml"
        fi
        fail "Cannot reach the cluster with $KUBECONFIG"
fi
ok "Cluster reachable: $(kubectl get nodes --no-headers | wc -l) nodes"

#############################################################
step "2. kubectl get prometheus -A"
#############################################################
kubectl get prometheus -A 2>/dev/null || true
mapfile -t PLIST < <(kubectl get prometheus -A --no-headers 2>/dev/null | awk '{print $1" "$2}')
[[ ${#PLIST[@]} -gt 0 ]] || fail "No Prometheus object in this cluster -> install monitoring first"
if [[ ${#PLIST[@]} -gt 1 ]]; then
        echo "  More than one Prometheus:"
        for i in "${!PLIST[@]}"; do echo "    $((i+1))) ${PLIST[$i]}"; done
        ask PSEL "Which one (number)" "1"
        PLINE=${PLIST[$((PSEL-1))]}
        [[ -n "$PLINE" ]] || fail "Invalid choice"
else
        PLINE=${PLIST[0]}
fi
PNS=${PLINE%% *}; PNAME=${PLINE##* }
ok "Using prometheus $PNAME in namespace $PNS"

pjp() { kubectl get prometheus -n "$PNS" "$PNAME" -o jsonpath="$1" 2>/dev/null; }

# existing remoteWrite entries
NRW=$(pjp '{range .spec.remoteWrite[*]}{.url}{"\n"}{end}' | grep -c .)
EXIST_NAMES=()
DEF_PIP=""
if [[ $NRW -eq 0 ]]; then
        info "No remoteWrite yet"
else
        info "Existing remoteWrite (kept as they are):"
        for ((i=0; i<NRW; i++)); do
                n=$(pjp "{.spec.remoteWrite[$i].name}")
                u=$(pjp "{.spec.remoteWrite[$i].url}")
                t=$(pjp "{.spec.remoteWrite[$i].headers.X-Scope-OrgID}")
                k=$(pjp "{.spec.remoteWrite[$i].writeRelabelConfigs[?(@.action==\"keep\")].regex}")
                p=$(pjp "{.spec.remoteWrite[$i].writeRelabelConfigs[?(@.targetLabel==\"public_ip\")].replacement}")
                info "  [$i] name=${n:-<none>}  url=$u  tenant=${t:-none}  keep=${k:-<all>}"
                EXIST_NAMES+=("$n")
                [[ -z "$DEF_PIP" && -n "$p" ]] && DEF_PIP=$p
                if [[ "$u" == "$RW_URL" && "$t" == "$RW_TENANT" ]]; then
                        warn "  [$i] already sends to $RW_URL tenant $RW_TENANT (adding another one would duplicate)"
                        DUP_TENANT=$i
                fi
        done
fi

#############################################################
step "3. Fields YOU fill (the red values in the manual)"
#############################################################
DEF_NAME=$(kubectl get nodes --no-headers | awk 'NR==1{print $1}' | sed -E 's/-(master|worker|control|cp|node)[^-]*(-[0-9]+)?$//I' | tr 'A-Z' 'a-z')
echo "  ---------------------------------------------------------------------------------"
echo "  1) name       : remoteWrite name, unique in this Prometheus   (manual example: ranchy)"
echo "  2) cluster    : label cluster= shown in Grafana               (manual example: urbanway)"
echo "  3) public_ip  : customer public IP, label public_ip=          (manual example: 203.150.145.39)"
echo "  Fixed        : url $RW_URL, secret $SECRET, tenant $RW_TENANT, regex \"$RW_REGEX\""
echo "  ---------------------------------------------------------------------------------"

while :; do
        ask RW_NAME "1) name" "$DEF_NAME"
        if [[ ! "$RW_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
                echo -e "  ${RED}Use letters, numbers, . _ - only (no spaces)${NC}"; RW_NAME=""; continue
        fi
        DUP=""
        for n in "${EXIST_NAMES[@]}"; do [[ "$n" == "$RW_NAME" ]] && DUP=1; done
        if [[ -n "$DUP" ]]; then
                echo -e "  ${RED}remoteWrite name '$RW_NAME' already exists - choose another name${NC}"; RW_NAME=""; continue
        fi
        break
done
while :; do
        ask CLUSTER_NAME "2) cluster" "$RW_NAME"
        [[ "$CLUSTER_NAME" =~ ^[A-Za-z0-9._-]+$ ]] && break
        echo -e "  ${RED}Use letters, numbers, . _ - only (no spaces)${NC}"; CLUSTER_NAME=""
done
while :; do
        ask PUBLIC_IP "3) public_ip" "$DEF_PIP"
        if [[ "$PUBLIC_IP" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] \
           && (( 10#${BASH_REMATCH[1]}<=255 && 10#${BASH_REMATCH[2]}<=255 && 10#${BASH_REMATCH[3]}<=255 && 10#${BASH_REMATCH[4]}<=255 )); then
                break
        fi
        echo -e "  ${RED}Enter an IPv4 address, e.g. 203.150.145.39${NC}"; PUBLIC_IP=""
done

# secret mimir-auth must be in the Prometheus namespace
NEED_SECRET=""
if kubectl get secret -n "$PNS" "$SECRET" >/dev/null 2>&1; then
        U=$(kubectl get secret -n "$PNS" "$SECRET" -o jsonpath='{.data.username}' 2>/dev/null)
        P=$(kubectl get secret -n "$PNS" "$SECRET" -o jsonpath='{.data.password}' 2>/dev/null)
        [[ -n "$U" && -n "$P" ]] || fail "Secret $PNS/$SECRET exists but has no username/password keys - fix it first"
        unset U P
        ok "Secret $PNS/$SECRET exists (username/password)"
else
        warn "Secret $PNS/$SECRET not found (manual step 'Create Secret')"
        echo "  Type the OLS Mimir basic-auth (input hidden for password, not saved to any file):"
        while [[ -z "$MIMIR_USER" ]]; do read -r -p "  Mimir username: " MIMIR_USER; done
        while [[ -z "$MIMIR_PASS" ]]; do read -r -s -p "  Mimir password: " MIMIR_PASS; echo ""; done
        NEED_SECRET=1
fi

#############################################################
step "4. Plan"
#############################################################
[[ -n "$NEED_SECRET" ]] && echo "  kubectl create secret generic $SECRET -n $PNS  (username=$MIMIR_USER, password=****)"
echo "  Append to prometheus $PNAME (-n $PNS):"
echo ""
cat <<EOF
  remoteWrite:
    - url: $RW_URL
      name: $RW_NAME
      basicAuth:
        username:
          name: $SECRET
          key: username
        password:
          name: $SECRET
          key: password
      headers:
        "X-Scope-OrgID": $RW_TENANT
      writeRelabelConfigs:
        - action: keep
          sourceLabels: [__name__]
          regex: "$RW_REGEX"
        - action: replace
          replacement: $CLUSTER_NAME
          targetLabel: cluster
        - action: replace
          replacement: "$PUBLIC_IP"
          targetLabel: public_ip
EOF
echo ""
[[ -n "$DUP_TENANT" ]] && warn "remoteWrite[$DUP_TENANT] already sends to tenant $RW_TENANT - this adds a second one"
if [[ "$ASSUME_YES" != y ]]; then
        read -r -p "  Apply now? [y/N]: " GO
        [[ "$GO" =~ ^[Yy]$ ]] || { echo "  Cancelled - nothing changed."; exit 0; }
fi

#############################################################
step "5. Apply"
#############################################################
mkdir -p "$WORKDIR"
BACKUP="$WORKDIR/prometheus-$PNAME.$(date +%Y%m%d-%H%M%S).backup.yaml"
kubectl get prometheus -n "$PNS" "$PNAME" -o yaml > "$BACKUP" || fail "Cannot back up the Prometheus object"
ok "Backup: $BACKUP"

if [[ -n "$NEED_SECRET" ]]; then
        # values go through a process substitution, not the command line (not visible in ps)
        kubectl create secret generic "$SECRET" -n "$PNS" \
                --from-env-file=<(printf 'username=%s\npassword=%s\n' "$MIMIR_USER" "$MIMIR_PASS") \
                || fail "Cannot create secret $PNS/$SECRET"
        unset MIMIR_PASS
        ok "Secret $PNS/$SECRET created"
fi

ENTRY=$(printf '{"url":"%s","name":"%s","basicAuth":{"username":{"name":"%s","key":"username"},"password":{"name":"%s","key":"password"}},"headers":{"X-Scope-OrgID":"%s"},"writeRelabelConfigs":[{"action":"keep","sourceLabels":["__name__"],"regex":"%s"},{"action":"replace","replacement":"%s","targetLabel":"cluster"},{"action":"replace","replacement":"%s","targetLabel":"public_ip"}]}' \
        "$RW_URL" "$RW_NAME" "$SECRET" "$SECRET" "$RW_TENANT" "$RW_REGEX" "$CLUSTER_NAME" "$PUBLIC_IP")
if [[ $NRW -eq 0 ]]; then
        PATCH="[{\"op\":\"add\",\"path\":\"/spec/remoteWrite\",\"value\":[$ENTRY]}]"
else
        PATCH="[{\"op\":\"add\",\"path\":\"/spec/remoteWrite/-\",\"value\":$ENTRY}]"
fi
kubectl patch prometheus -n "$PNS" "$PNAME" --type=json -p="$PATCH" || fail "kubectl patch failed (backup: $BACKUP)"
ok "remoteWrite '$RW_NAME' added"

case "$PNAME" in rancher-monitoring-*|kube-prometheus-stack-*)
        warn "Prometheus is Helm-managed: also put this remoteWrite in the app values"
        info "(Rancher > Apps > Installed Apps > ${PNAME%-prometheus} > Edit YAML > prometheus.prometheusSpec.remoteWrite)"
        info "or the next upgrade of the monitoring app removes it" ;;
esac

#############################################################
step "6. Verify (Prometheus reloads config in 1-3 min, waiting up to 4 min)"
#############################################################
PPOD=$(kubectl get pod -n "$PNS" -l "operator.prometheus.io/name=$PNAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -z "$PPOD" ]] && PPOD="prometheus-$PNAME-0"
pval() { kubectl exec -n "$PNS" "$PPOD" -c prometheus -- promtool query instant http://localhost:9090 "$1" 2>/dev/null \
        | grep ' => ' | awk -F' => ' 'NR==1{split($2,a," "); print a[1]}'; }

if [[ "$(pval 'vector(1)')" != 1 ]]; then
        warn "Cannot query Prometheus (kubectl exec not allowed?) - check later with observe-check.sh"
else
        SENT=""
        for i in $(seq 1 24); do
                SENT=$(pval "sum(increase(prometheus_remote_storage_samples_total{remote_name=\"$RW_NAME\"}[2m]))")
                [[ -n "$SENT" ]] && awk "BEGIN{exit !($SENT > 0)}" && break
                printf "\r         waiting for Prometheus to load the new remoteWrite... %ss " "$((i*10))"
                sleep 10
        done
        echo ""
        FAILED=$(pval "sum(increase(prometheus_remote_storage_samples_failed_total{remote_name=\"$RW_NAME\"}[2m]))")
        if [[ -n "$SENT" ]] && awk "BEGIN{exit !($SENT > 0)}"; then
                if [[ -n "$FAILED" ]] && awk "BEGIN{exit !($FAILED > 0)}"; then
                        warn "Sending, but some samples FAILED (wrong user/password? tenant?)"
                        info "kubectl logs -n $PNS $PPOD -c prometheus | grep -i remote | tail"
                else
                        ok "'$RW_NAME' is sending to OLS Observe (samples in last 2m: ${SENT%.*}, failed: 0)"
                fi
        else
                warn "No samples sent yet. Check: kubectl logs -n $PNS $PPOD -c prometheus | grep -i remote | tail"
                info "Common causes: no x509_/probe_ metrics in this cluster yet, wrong password (401), egress blocked"
        fi
fi

echo ""
echo -e "${GREEN}${bold}Done.${normal}${NC} cluster=$CLUSTER_NAME public_ip=$PUBLIC_IP -> $RW_URL (tenant $RW_TENANT)"
echo "  Full check : bash <(curl -s https://raw.githubusercontent.com/Hayato360/Script/refs/heads/main/observe-check.sh)"
echo "  Grafana    : wait 2-3 min, then reload the dashboard page (F5)"
if [[ $NRW -eq 0 ]]; then UNDO_PATH=/spec/remoteWrite; else UNDO_PATH=/spec/remoteWrite/$NRW; fi
echo "  Undo       : kubectl patch prometheus -n $PNS $PNAME --type=json -p='[{\"op\":\"remove\",\"path\":\"$UNDO_PATH\"}]'"
echo "  Backup     : $BACKUP"
echo ""
