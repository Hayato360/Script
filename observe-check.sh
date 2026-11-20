#!/bin/bash
#############################################################################
# OLS Observe check  (READ-ONLY - changes nothing on the machine / cluster)
#
# Checks one cluster for the tracking-sheet columns:
#   Prometheus : is there a Prometheus (rancher-monitoring / kube-prometheus-stack)?
#   Cert       : x509 metrics exist + remoteWrite to OLS Observe (Mimir) works
#   Blackbox   : blackbox-exporter + Probe CRs exist, probes succeed, probe_* is pushed
#
# Run on : a master node or the Rancher VM, any user that has kubectl + kubeconfig
# Usage  : bash <(curl -s https://raw.githubusercontent.com/Hayato360/Script/refs/heads/main/observe-check.sh)
#
# Optional env:
#   KUBECONFIG=/path/kubeconfig   (auto: $KUBECONFIG, rke2.yaml, ~/.kube/config, /root/.kube/kubeconfig)
#   CERT_WARN_DAYS=30             (warn when a cert expires within N days)
#   OBSERVE_HOST=metrics-gateway.olsxops.com
#
# Only uses: kubectl get / kubectl exec "promtool query" (a read query) / curl HEAD.
# If kubectl is missing but a kubeconfig exists, it can download a TEMPORARY kubectl
# to /tmp/observe-check.* (asks first, or KUBECTL_DOWNLOAD=y) and deletes it at exit.
# RKE1 (Docker) nodes have no admin kubeconfig -> run from the Rancher VM instead.
#############################################################################

PATH=$PATH:/var/lib/rancher/rke2/bin:/usr/local/bin
CERT_WARN_DAYS=${CERT_WARN_DAYS:-30}
OBSERVE_HOST=${OBSERVE_HOST:-metrics-gateway.olsxops.com}
BB_TENANT=${BB_TENANT:-rancher-health}   # tenant (X-Scope-OrgID) the Blackbox dashboard reads
X509_PUSH=""; PROBE_PUSH=""

bold=$(tput bold 2>/dev/null)
normal=$(tput sgr0 2>/dev/null)
RED='\e[0;31m'
GREEN='\e[0;32m'
YELLOW='\e[0;33m'
CYAN='\e[0;36m'
NC='\e[0m'

step() { echo ""; echo -e "${CYAN}${bold}==> $*${normal}${NC}"; }
ok()   { echo -e "  ${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; WARNS=$((WARNS+1)); }
bad()  { echo -e "  ${RED}[FAIL]${NC} $*"; }
info() { echo -e "         $*"; }

WARNS=0
RES_PROM="-"; RES_RW="-"; RES_CERT="-"; RES_BB="-"
NOTE_PROM=""; NOTE_RW=""; NOTE_CERT=""; NOTE_BB=""

echo ""
echo -e "${CYAN}########################################################################################${NC}"
echo -e "  ${bold}OLS Observe check${normal} (read-only)  -  Prometheus / Cert / Blackbox"
echo -e "${CYAN}########################################################################################${NC}"

#############################################################
step "1. Cluster access"
#############################################################
# --- what kind of node is this? --------------------------------------------------
KIND=""
if [[ -x /var/lib/rancher/rke2/bin/kubectl || -f /etc/rancher/rke2/rke2.yaml ]]; then KIND=RKE2
elif command -v k3s >/dev/null 2>&1; then KIND=K3S
elif command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx kubelet; then KIND=RKE1
fi
[[ -n "$KIND" ]] && info "Node type: $KIND"

# --- kubeconfig -------------------------------------------------------------------
if [[ -z "$KUBECONFIG" ]]; then
        for f in /etc/rancher/rke2/rke2.yaml /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config" /root/.kube/kubeconfig /root/.kube/config \
                 /root/kube_config_*.yml /home/*/kube_config_*.yml /home/*/.kube/config; do
                if [[ -r "$f" ]]; then export KUBECONFIG=$f; break; fi
        done
fi

# --- kubectl ----------------------------------------------------------------------
TMPK=""
cleanup() { [[ -n "$TMPK" ]] && rm -rf "$TMPK"; }
trap cleanup EXIT
if ! command -v kubectl >/dev/null 2>&1; then
        if [[ "$KIND" == K3S ]]; then
                kubectl() { k3s kubectl "$@"; }
                info "Using 'k3s kubectl'"
        elif [[ -z "$KUBECONFIG" ]]; then
                bad "kubectl not found and no kubeconfig on this machine"
                if [[ "$KIND" == RKE1 ]]; then
                        info "This is an RKE1 (Docker) node: it has no admin kubeconfig."
                fi
                info "Run it where a kubeconfig of this cluster exists, e.g. the Rancher VM:"
                info "  Rancher UI > cluster > Download KubeConfig > save as /root/.kube/<cluster>.yaml"
                info "  KUBECONFIG=/root/.kube/<cluster>.yaml bash <(curl -s https://raw.githubusercontent.com/Hayato360/Script/refs/heads/main/observe-check.sh)"
                info "Or copy that kubeconfig to this node as /root/.kube/config and run again."
                exit 1
        else
                warn "kubectl not found, but kubeconfig $KUBECONFIG exists"
                if [[ "${KUBECTL_DOWNLOAD:-}" != y ]]; then
                        read -r -p "         Download a TEMPORARY kubectl to /tmp (deleted when the script ends)? [y/N]: " KUBECTL_DOWNLOAD
                fi
                if [[ "$KUBECTL_DOWNLOAD" =~ ^[Yy]$ ]]; then
                        TMPK=$(mktemp -d /tmp/observe-check.XXXXXX)
                        KV=$(curl -sL -m 15 https://dl.k8s.io/release/stable.txt)
                        ARCH=$(uname -m); [[ "$ARCH" == aarch64 ]] && ARCH=arm64 || ARCH=amd64
                        if [[ "$KV" == v* ]] && curl -sL -m 120 -o "$TMPK/kubectl" "https://dl.k8s.io/release/$KV/bin/linux/$ARCH/kubectl" && chmod +x "$TMPK/kubectl" && "$TMPK/kubectl" version --client >/dev/null 2>&1; then
                                PATH=$TMPK:$PATH
                                ok "Temporary kubectl $KV in $TMPK (removed at exit)"
                        else
                                bad "Could not download kubectl (no internet?)"; exit 1
                        fi
                else
                        bad "kubectl not found"; exit 1
                fi
        fi
fi
info "KUBECONFIG = ${KUBECONFIG:-(kubectl default)}"

if ! kubectl get nodes >/dev/null 2>&1; then
        bad "Cannot reach the cluster with this kubeconfig"
        KERR=$(kubectl get nodes 2>&1)
        echo "$KERR" | grep -v memcache.go | head -3 | sed 's/^/         /'
        if grep -qiE 'system:unauthenticated|Unauthorized|token' <<<"$KERR"; then
                info "-> Kubeconfig token expired/deleted. Rancher UI > Cluster Management > cluster > Download KubeConfig,"
                info "   save as /root/.kube/<cluster>.yaml and run with KUBECONFIG=/root/.kube/<cluster>.yaml"
        fi
        exit 1
fi
NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
NOTREADY=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 !~ /^Ready/' | wc -l)
K8SVER=$(kubectl get nodes --no-headers 2>/dev/null | awk 'NR==1{print $5}')
ok "Cluster reachable: $NODES nodes, version $K8SVER"
[[ $NOTREADY -gt 0 ]] && warn "$NOTREADY node(s) NotReady"
info "Host: $(hostname)   Date: $(date '+%F %T %Z')"

#############################################################
step "2. Prometheus"
#############################################################
if ! kubectl get crd prometheuses.monitoring.coreos.com >/dev/null 2>&1; then
        bad "No Prometheus Operator CRDs -> no monitoring installed"
        RES_PROM="FAIL"; NOTE_PROM="ไม่มี Prometheus"
else
        kubectl get prometheus -A 2>/dev/null
        PLINE=$(kubectl get prometheus -A --no-headers 2>/dev/null | head -1)
        if [[ -z "$PLINE" ]]; then
                bad "CRDs exist but no Prometheus object"
                RES_PROM="FAIL"; NOTE_PROM="ไม่มี Prometheus"
        else
                PNS=$(awk '{print $1}' <<<"$PLINE")
                PNAME=$(awk '{print $2}' <<<"$PLINE")
                [[ $(kubectl get prometheus -A --no-headers | wc -l) -gt 1 ]] && warn "More than one Prometheus, checking only $PNS/$PNAME"

                # which chart
                case "$PNAME" in
                        rancher-monitoring-*)    CHART="rancher-monitoring (Rancher < v2.15 app)"; REL=rancher-monitoring ;;
                        kube-prometheus-stack-*) CHART="kube-prometheus-stack"; REL=kube-prometheus-stack ;;
                        *)                       CHART="unknown chart"; REL="" ;;
                esac
                PVER=$(kubectl get prometheus -n "$PNS" "$PNAME" -o jsonpath='{.spec.version}' 2>/dev/null)
                ok "Prometheus $PNS/$PNAME  ($CHART, ${PVER:-version ?})"

                PPOD=$(kubectl get pod -n "$PNS" -l "operator.prometheus.io/name=$PNAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
                [[ -z "$PPOD" ]] && PPOD=$(kubectl get pod -n "$PNS" -l "prometheus=$PNAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
                [[ -z "$PPOD" ]] && PPOD="prometheus-$PNAME-0"
                PPHASE=$(kubectl get pod -n "$PNS" "$PPOD" -o jsonpath='{.status.phase}' 2>/dev/null)
                PREADY=$(kubectl get pod -n "$PNS" "$PPOD" -o jsonpath='{.status.containerStatuses[?(@.name=="prometheus")].ready}' 2>/dev/null)
                if [[ "$PPHASE" == "Running" && "$PREADY" == "true" ]]; then
                        ok "Pod $PPOD Running/Ready"
                        RES_PROM="OK"
                else
                        bad "Pod $PPOD phase=${PPHASE:-missing} ready=${PREADY:-?}"
                        RES_PROM="FAIL"; NOTE_PROM="Prometheus pod not ready"
                fi

                # operator view: Available / Reconciled conditions (catches config-reload problems)
                for ct in Available Reconciled; do
                        cs=$(kubectl get prometheus -n "$PNS" "$PNAME" -o jsonpath="{.status.conditions[?(@.type==\"$ct\")].status}" 2>/dev/null)
                        [[ -z "$cs" || "$cs" == True ]] && continue
                        cm=$(kubectl get prometheus -n "$PNS" "$PNAME" -o jsonpath="{.status.conditions[?(@.type==\"$ct\")].reason}: {.status.conditions[?(@.type==\"$ct\")].message}" 2>/dev/null)
                        bad "Prometheus $ct=$cs  ${cm:0:300}"
                        PROM_DEGRADED="Prometheus $ct=$cs (see reason above)"
                done
                NRC=$(kubectl get pod -n "$PNS" "$PPOD" -o jsonpath='{range .status.containerStatuses[*]}{.name}={.ready} {end}' 2>/dev/null)
                [[ "$NRC" == *=false* ]] && warn "Containers not ready: $NRC"

                PVC=$(kubectl get pvc -n "$PNS" --no-headers 2>/dev/null | grep "prometheus-$PNAME" | awk '{print $1" "$2" "$4" "$6}')
                [[ -n "$PVC" ]] && info "PVC: $PVC" || warn "Prometheus has no PVC (data lost on restart)"
        fi
fi

# --- query helper (promtool inside the prometheus pod, read-only query) -----------
QMODE=""
promq() {
        kubectl exec -n "$PNS" "$PPOD" -c prometheus -- promtool query instant http://localhost:9090 "$1" 2>/dev/null
}
# first value of a query (or empty)
pval() { promq "$1" | grep ' => ' | awk -F' => ' 'NR==1{split($2,a," "); print a[1]}'; }
# "labels => value" lines only (promtool prints a blank line for an empty result)
plist() { promq "$1" | grep ' => ' | sed -E 's/ @\[.*$//'; }
lbl() { grep -o "$1=\"[^\"]*\"" | head -1 | cut -d'"' -f2; }

if [[ "$RES_PROM" == "OK" ]]; then
        if [[ "$(pval 'vector(1)')" == "1" ]]; then
                QMODE=promtool
                ok "Can query Prometheus (promtool)"
                RELOAD_OK=$(pval 'prometheus_config_last_reload_successful')
                if [[ "$RELOAD_OK" == 0 ]]; then
                        bad "Prometheus config reload FAILED -> runs on an OLD config (new remoteWrite/scrape jobs not active)"
                        info "see: kubectl logs -n $PNS $PPOD -c prometheus --tail=300 | grep -iE 'error loading config|reload'"
                        PROM_DEGRADED="config reload failed"
                fi
                RST=$(kubectl get pod -n "$PNS" "$PPOD" -o jsonpath='{.status.containerStatuses[?(@.name=="prometheus")].restartCount}' 2>/dev/null)
                RSN=$(kubectl get pod -n "$PNS" "$PPOD" -o jsonpath='{.status.containerStatuses[?(@.name=="prometheus")].lastState.terminated.reason}' 2>/dev/null)
                [[ -n "$RST" && "$RST" -gt 0 ]] 2>/dev/null && warn "prometheus container restarts=$RST${RSN:+ (last: $RSN)}"
        else
                warn "Cannot run promtool query in $PPOD (no exec permission?) - metric checks skipped"
        fi
fi

#############################################################
step "3. Remote write -> OLS Observe ($OBSERVE_HOST)"
#############################################################
if [[ "$RES_PROM" == "-" || -z "$PNAME" ]]; then
        bad "Skipped (no Prometheus)"
        RES_RW="FAIL"; NOTE_RW="ไม่มี Prometheus"
else
        RW_URLS=$(kubectl get prometheus -n "$PNS" "$PNAME" -o jsonpath='{range .spec.remoteWrite[*]}{.url}{"\n"}{end}' 2>/dev/null)
        if [[ -z "$RW_URLS" ]]; then
                bad "No spec.remoteWrite on $PNS/$PNAME"
                RES_RW="FAIL"; NOTE_RW="ยังไม่ได้ตั้ง remoteWrite"
        else
                IDX=-1; i=0
                while read -r u; do
                        info "remoteWrite[$i]: $u"
                        [[ "$u" == *"$OBSERVE_HOST"* && $IDX -lt 0 ]] && IDX=$i
                        i=$((i+1))
                done <<<"$RW_URLS"
                if [[ $IDX -lt 0 ]]; then
                        bad "No remoteWrite to $OBSERVE_HOST (old URL? mimir-gateway.metrics.olsxops.com -> $OBSERVE_HOST)"
                        RES_RW="FAIL"; NOTE_RW="remoteWrite URL ผิด"
                else
                        RW="{.spec.remoteWrite[$IDX]"
                        jp() { kubectl get prometheus -n "$PNS" "$PNAME" -o jsonpath="$RW$1}" 2>/dev/null; }
                        RW_NAME=$(jp '.name')
                        RW_HDR=$(jp '.headers')
                        RW_KEEP=$(jp '.writeRelabelConfigs[?(@.action=="keep")].regex')
                        RW_CLUSTER=$(jp '.writeRelabelConfigs[?(@.targetLabel=="cluster")].replacement')
                        RW_PIP=$(jp '.writeRelabelConfigs[?(@.targetLabel=="public_ip")].replacement')
                        RW_SECRET=$(jp '.basicAuth.username.name')
                        RW_UKEY=$(jp '.basicAuth.username.key')
                        RW_PKEY=$(jp '.basicAuth.password.key')

                        ok "remoteWrite name=${RW_NAME:-?}  headers=${RW_HDR:-none}"
                        info "keep regex  : ${RW_KEEP:-(none - ALL metrics are pushed)}"
                        info "cluster     : ${RW_CLUSTER:-(not set)}"
                        info "public_ip   : ${RW_PIP:-(not set)}"
                        RW_OK=1
                        [[ "$RW_HDR" == *X-Scope-OrgID* ]] || { warn "No X-Scope-OrgID header (tenant)"; }
                        [[ -z "$RW_CLUSTER" ]] && warn "No cluster label relabel -> cannot tell clusters apart in Grafana"
                        [[ -z "$RW_PIP" ]] && warn "No public_ip label relabel"
                        # look at ALL entries to Observe: which tenant gets x509_ / probe_ ?
                        X509_PUSH=0; PROBE_PUSH=0; PROBE_OTHER=""
                        NRW=$(grep -c . <<<"$RW_URLS")
                        for ((j=0; j<NRW; j++)); do
                                pj() { kubectl get prometheus -n "$PNS" "$PNAME" -o jsonpath="{.spec.remoteWrite[$j]$1}" 2>/dev/null; }
                                [[ "$(pj '.url')" == *"$OBSERVE_HOST"* ]] || continue
                                jn=$(pj '.name')
                                jt=$(pj '.headers.X-Scope-OrgID')
                                jk=$(pj '.writeRelabelConfigs[?(@.action=="keep")].regex')
                                js=""
                                if [[ "$QMODE" == promtool && -n "$jn" ]]; then
                                        js=$(pval "sum(rate(prometheus_remote_storage_samples_total{remote_name=\"$jn\"}[5m]))")
                                fi
                                info "remoteWrite[$j] name=$jn tenant=${jt:-none} keep=${jk:-<all>}  sent=${js:-0}/s"
                                [[ -z "$jk" || "$jk" == *x509_* ]] && X509_PUSH=1
                                if [[ -z "$jk" || "$jk" == *probe_* ]]; then
                                        if [[ "$jt" == "$BB_TENANT" ]]; then
                                                PROBE_PUSH=1
                                                if [[ "$QMODE" == promtool ]] && { [[ -z "$js" ]] || awk "BEGIN{exit !($js <= 0)}"; }; then
                                                        warn "$jn is configured but NOT sending yet (Prometheus reloads config in 1-3 min - re-run later)"
                                                fi
                                        else PROBE_OTHER=${jt:-none}; fi
                                fi
                        done
                        [[ $X509_PUSH -eq 1 ]] || warn "No remoteWrite keeps x509_ -> cert metrics NOT pushed"
                        if [[ $PROBE_PUSH -eq 1 ]]; then
                                ok "probe_* is pushed to tenant $BB_TENANT (Blackbox dashboard)"
                        elif [[ -n "$PROBE_OTHER" ]]; then
                                warn "probe_* goes to tenant '$PROBE_OTHER', but the Blackbox dashboard reads '$BB_TENANT' -> cluster not shown"
                        else
                                warn "No remoteWrite sends probe_* to tenant '$BB_TENANT' -> blackbox NOT in Observe"
                        fi

                        # basic auth secret (only check keys exist, never print values)
                        if [[ -z "$RW_SECRET" ]]; then
                                warn "No basicAuth on remoteWrite"
                        elif kubectl get secret -n "$PNS" "$RW_SECRET" >/dev/null 2>&1; then
                                U=$(kubectl get secret -n "$PNS" "$RW_SECRET" -o jsonpath="{.data.$RW_UKEY}" 2>/dev/null)
                                P=$(kubectl get secret -n "$PNS" "$RW_SECRET" -o jsonpath="{.data.$RW_PKEY}" 2>/dev/null)
                                if [[ -n "$U" && -n "$P" ]]; then ok "Secret $PNS/$RW_SECRET has keys $RW_UKEY/$RW_PKEY"
                                else bad "Secret $PNS/$RW_SECRET missing key $RW_UKEY or $RW_PKEY"; RW_OK=0; fi
                                unset U P
                        else
                                bad "Secret $PNS/$RW_SECRET not found (must be in the Prometheus namespace)"; RW_OK=0
                        fi

                        # managed by Helm? manual kubectl edit is overwritten on next helm upgrade
                        HELM_RW=$(kubectl get secret -n "$PNS" -l "owner=helm,name=$REL,status=deployed" -o name 2>/dev/null | head -1)
                        [[ -n "$HELM_RW" ]] && info "Prometheus is Helm-managed ($REL): keep remoteWrite in values.yaml, not only kubectl edit"

                        # is it actually sending?
                        if [[ "$QMODE" == promtool ]]; then
                                SENT=$(pval "sum(rate(prometheus_remote_storage_samples_total{url=~\".*$OBSERVE_HOST.*\"}[5m]))")
                                FAILR=$(pval "sum(rate(prometheus_remote_storage_samples_failed_total{url=~\".*$OBSERVE_HOST.*\"}[5m]))")
                                LAG=$(pval "max(time() - prometheus_remote_storage_queue_highest_sent_timestamp_seconds{url=~\".*$OBSERVE_HOST.*\"})")
                                [[ -n "$LAG" ]] && awk "BEGIN{exit !($LAG > 1000000000)}" && LAG="never"
                                info "sent=${SENT:-0}/s  failed=${FAILR:-0}/s  last-sent-lag=${LAG:-?}${LAG:+s}"
                                if [[ -z "$SENT" ]] || awk "BEGIN{exit !(${SENT:-0} <= 0)}"; then
                                        HAVE=$(pval 'count({__name__=~"x509_.*|probe_.*"})')
                                        if [[ -z "$HAVE" ]]; then
                                                warn "Nothing to send yet: this cluster has no x509_* / probe_* metrics (install Cert exporter / Blackbox first)"
                                                RW_IDLE=1
                                        else
                                                bad "Nothing sent to $OBSERVE_HOST in last 5m (but $HAVE x509_/probe_ series exist -> reload/auth/egress problem)"; RW_OK=0
                                        fi
                                elif [[ -n "$FAILR" ]] && awk "BEGIN{exit !($FAILR > 0)}"; then
                                        bad "Remote write has failures (auth 401/403? network?) - check: kubectl logs -n $PNS $PPOD -c prometheus | grep -i remote"; RW_OK=0
                                elif [[ -n "$LAG" ]] && awk "BEGIN{exit !($LAG > 300)}"; then
                                        warn "Remote write lag > 5 min"
                                else
                                        ok "Remote write is sending without failures"
                                fi
                        fi
                        if [[ $RW_OK -eq 1 && -n "$RW_IDLE" ]]; then RES_RW="OK"; NOTE_RW="ตั้งค่าถูก แต่ยังไม่มี x509/probe metrics ให้ส่ง"
                        elif [[ $RW_OK -eq 1 ]]; then RES_RW="OK"
                        else RES_RW="FAIL"; NOTE_RW="remoteWrite ส่งไม่ได้"; fi
                fi
        fi
fi

# network from this host (info only - Prometheus pod egress can differ)
if command -v curl >/dev/null 2>&1; then
        CODE=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "https://$OBSERVE_HOST/api/v1/push" 2>/dev/null)
        if [[ "$CODE" == "000" || -z "$CODE" ]]; then
                warn "This host cannot reach https://$OBSERVE_HOST (proxy/firewall?)"
        else
                info "This host -> https://$OBSERVE_HOST : HTTP $CODE (401/405 = reachable)"
        fi
fi

#############################################################
step "4. Cert (x509 metrics)"
#############################################################
X509_PODS=$(kubectl get pod -A --no-headers 2>/dev/null | grep -i x509)
if [[ -n "$X509_PODS" ]]; then
        echo "$X509_PODS" | awk '{printf "         %-28s %-50s %s %s\n",$1,$2,$3,$4}'
else
        info "No x509-certificate-exporter pod found"
fi

if [[ "$RES_PROM" != "OK" ]]; then
        bad "Skipped (no Prometheus)"; RES_CERT="FAIL"; NOTE_CERT="ไม่มี Prometheus"
elif [[ "$QMODE" != promtool ]]; then
        warn "Cannot query Prometheus"; RES_CERT="?"
else
        X509N=$(pval 'count(x509_cert_not_after)')
        SSLN=$(pval 'count(probe_ssl_earliest_cert_expiry)')
        if [[ -n "$X509N" ]]; then
                ok "x509_cert_not_after: $X509N cert(s)"
                info "Soonest expiring (days left):"
                plist 'bottomk(5, (x509_cert_not_after - time()) / 86400)' | while IFS= read -r l; do
                        d=$(awk -F' => ' '{printf "%.0f",$2}' <<<"$l")
                        n=$(lbl subject_CN <<<"$l"); [[ -z "$n" ]] && n=$(lbl secret_name <<<"$l"); [[ -z "$n" ]] && n=$(lbl filepath <<<"$l")
                        printf "           %6s  %s\n" "$d" "$n"
                done
                EXP=$(pval "count((x509_cert_not_after - time()) / 86400 < $CERT_WARN_DAYS)")
                [[ -n "$EXP" ]] && warn "$EXP cert(s) expire within $CERT_WARN_DAYS days"
                RES_CERT="OK"
        elif [[ -n "$SSLN" ]]; then
                ok "No x509_* metrics, but blackbox probe_ssl_earliest_cert_expiry has $SSLN target(s)"
                plist 'bottomk(5, (probe_ssl_earliest_cert_expiry - time()) / 86400)' | while IFS= read -r l; do
                        d=$(awk -F' => ' '{printf "%.0f",$2}' <<<"$l")
                        printf "           %6s  %s\n" "$d" "$(lbl instance <<<"$l")"
                done
                RES_CERT="OK"; NOTE_CERT="cert จาก blackbox (ไม่มี x509 exporter)"
        else
                bad "No x509_* or probe_ssl_* metrics in Prometheus"
                RES_CERT="FAIL"; NOTE_CERT="ไม่มี cert metrics"
        fi
        if [[ "$RES_CERT" == "OK" && "$RES_RW" != "OK" ]]; then
                RES_CERT="FAIL"; NOTE_CERT="มี cert metrics แต่ไม่ได้ส่งไป Observe"
        fi
        if [[ "$RES_CERT" == "OK" && "$X509_PUSH" == 0 && -n "$X509N" ]]; then
                RES_CERT="FAIL"; NOTE_CERT="keep regex ไม่มี x509_"
        fi
fi

#############################################################
step "5. Blackbox exporter + Probes"
#############################################################
BB_OK=1
BB_DEP=$(kubectl get deploy -A --no-headers 2>/dev/null | grep -i blackbox)
if [[ -z "$BB_DEP" ]]; then
        bad "No blackbox-exporter Deployment"
        BB_OK=0; NOTE_BB="ไม่มี blackbox exporter"
else
        echo "$BB_DEP" | while read -r ns n rdy _; do
                if [[ "${rdy%/*}" == "${rdy#*/}" && "${rdy%/*}" != "0" ]]; then ok "Deployment $ns/$n $rdy"
                else bad "Deployment $ns/$n $rdy"; fi
        done
        echo "$BB_DEP" | awk '{split($3,a,"/"); if (a[1]!=a[2] || a[1]==0) exit 1}' || { BB_OK=0; NOTE_BB="blackbox pod ไม่ ready"; }
        info "Services:"
        kubectl get svc -A --no-headers 2>/dev/null | grep -i blackbox | awk '{printf "           %s.%s.svc  %s\n",$2,$1,$6}'
fi

if ! kubectl get crd probes.monitoring.coreos.com >/dev/null 2>&1; then
        bad "No Probe CRD"; BB_OK=0
else
        PROBES=$(kubectl get probes.monitoring.coreos.com -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.spec.module}{"|"}{.spec.prober.url}{"|"}{.metadata.labels.release}{"|"}{.spec.targets.staticConfig.static}{"\n"}{end}' 2>/dev/null)
        if [[ -z "$PROBES" ]]; then
                bad "No Probe objects"; BB_OK=0; [[ -z "$NOTE_BB" ]] && NOTE_BB="ไม่มี Probe"
        else
                # what Prometheus selects
                PSEL=""; PNSSEL=""
                if [[ -n "$PNAME" ]]; then
                        PSEL=$(kubectl get prometheus -n "$PNS" "$PNAME" -o jsonpath='{.spec.probeSelector.matchLabels.release}' 2>/dev/null)
                        PSELRAW=$(kubectl get prometheus -n "$PNS" "$PNAME" -o jsonpath='{.spec.probeSelector}' 2>/dev/null)
                        PNSSEL=$(kubectl get prometheus -n "$PNS" "$PNAME" -o jsonpath='{.spec.probeNamespaceSelector}' 2>/dev/null)
                        info "Prometheus probeSelector=${PSELRAW:-<nil: none selected>}  probeNamespaceSelector=${PNSSEL:-<nil: own ns only>}"
                fi
                while IFS='|' read -r ns n mod url rel tg; do
                        [[ -z "$n" ]] && continue
                        cnt=$(grep -o '"[^"]*"' <<<"$tg" | wc -l)
                        echo -e "  ${bold}Probe $ns/$n${normal}  module=$mod  targets=$cnt  release=${rel:-<none>}"
                        info "prober: $url"
                        # prober service exists?
                        host=${url#*://}; host=${host%%/*}; host=${host%%:*}
                        svc=${host%%.*}; rest=${host#*.}; sns=${rest%%.*}
                        [[ "$sns" == "$host" || "$sns" == "svc" || -z "$sns" ]] && sns=$ns
                        if kubectl get svc -n "$sns" "$svc" >/dev/null 2>&1; then ok "prober service $sns/$svc exists"
                        else bad "prober service $sns/$svc NOT found -> probe cannot run (wrong prober.url)"; BB_OK=0; fi
                        # selected by Prometheus?
                        if [[ -n "$PNAME" ]]; then
                                if [[ -z "$PSELRAW" ]]; then
                                        bad "Prometheus probeSelector is nil -> Probe ignored"; BB_OK=0
                                elif [[ -n "$PSEL" && "$PSEL" != "$rel" ]]; then
                                        bad "label release=${rel:-<none>} but Prometheus wants release=$PSEL -> Probe ignored"; BB_OK=0
                                fi
                                if [[ -z "$PNSSEL" && "$ns" != "$PNS" ]]; then
                                        bad "Probe in ns $ns but probeNamespaceSelector is nil (only $PNS) -> Probe ignored"; BB_OK=0
                                fi
                        fi
                done <<<"$PROBES"
        fi
fi

if [[ "$QMODE" == promtool ]]; then
        PTOT=$(pval 'count(probe_success)')
        if [[ -z "$PTOT" ]]; then
                bad "No probe_success metrics in Prometheus"; BB_OK=0; [[ -z "$NOTE_BB" ]] && NOTE_BB="Prometheus ไม่ได้ scrape probe"
        else
                PUP=$(pval 'count(probe_success == 1)'); PUP=${PUP:-0}
                ok "probe_success: $PUP / $PTOT targets up"
                plist 'probe_success == 0' | while IFS= read -r l; do
                        bad "DOWN  job=$(lbl job <<<"$l")  instance=$(lbl instance <<<"$l")"
                done
                plist 'up{job=~"probe/.*"} == 0' | while IFS= read -r l; do
                        bad "Scrape of blackbox failed  job=$(lbl job <<<"$l")  instance=$(lbl instance <<<"$l")"
                done
                [[ "$PUP" != "$PTOT" ]] && warn "$((PTOT-PUP)) probe target(s) down (exporter OK, target unreachable)"
        fi
elif [[ "$RES_PROM" == "OK" ]]; then
        warn "Cannot query Prometheus for probe_success"
fi

if [[ $BB_OK -eq 1 && "$RES_RW" != "OK" ]]; then
        BB_OK=0; NOTE_BB="probe มี แต่ไม่ได้ส่งไป Observe"
fi
if [[ $BB_OK -eq 1 && "$PROBE_PUSH" == 0 ]]; then
        BB_OK=0; NOTE_BB="probe_ ไม่ได้ส่งไป tenant $BB_TENANT"
fi
[[ "$RES_PROM" != "OK" && -z "$NOTE_BB" ]] && NOTE_BB="ไม่มี Prometheus"
[[ $BB_OK -eq 1 ]] && RES_BB="OK" || RES_BB="FAIL"

#############################################################
[[ -n "$PROM_DEGRADED" ]] && { RES_PROM="FAIL"; NOTE_PROM=$PROM_DEGRADED; }
FIRSTNODE=$(kubectl get nodes --no-headers 2>/dev/null | awk 'NR==1{print $1}')
step "Summary  (run on $(hostname), cluster: ${RW_CLUSTER:-$FIRSTNODE ...}, $NODES nodes)"
#############################################################
show() {
        local name=$1 res=$2 note=$3 c=$NC
        [[ "$res" == OK ]] && c=$GREEN
        [[ "$res" == FAIL ]] && c=$RED
        [[ "$res" == "?" ]] && c=$YELLOW
        printf "  %-12s ${c}%-5s${NC} %s\n" "$name" "$res" "$note"
}
show "Prometheus" "$RES_PROM" "$NOTE_PROM"
show "RemoteWrite" "$RES_RW" "$NOTE_RW"
show "Cert" "$RES_CERT" "$NOTE_CERT"
show "Blackbox" "$RES_BB" "$NOTE_BB"
[[ $WARNS -gt 0 ]] && echo -e "  ${YELLOW}$WARNS warning(s) above${NC}"
echo ""
echo "  (read-only check - nothing was changed)"
echo ""
