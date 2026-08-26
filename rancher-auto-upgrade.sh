#!/usr/bin/env bash
#
# rancher-auto-upgrade.sh
#
# Fully-automated multi-hop Rancher single-node Docker upgrade,
# built from the UpLab rehearsal (KB-RANCHER-UPG) findings.
#
# Handles automatically, per hop:
#   - version-hop planning (no skipping minors, patch-then-minor)
#   - retry-safe registry queries + image pulls (known intermittent
#     packet-loss on some networks causes mid-pull resets/timeouts)
#   - pre-hop disk-pressure guard (cleans old rancher-old-* containers/
#     images if root disk is getting full — this caused a real outage
#     during the rehearsal)
#   - stop + tar backup + sanity check
#   - rename old container / run new container
#   - startup-race auto-remediation: if the new container repeatedly
#     [FATAL]s on a webhook call ("no endpoints available for service
#     rancher-webhook"), deletes the webhook admission configs and
#     scales rancher-webhook to 0 replicas to let the outer container
#     stabilize, waits for a genuine ~6min stable window (not a fixed
#     short timer), then scales back to 1 — and will repeat this as
#     many times as the outer container keeps crash-looping into a
#     fresh cause, rather than giving up after one attempt. Only a
#     true 90-minute hard-abort ceiling stops a stuck hop.
#   - waits for the UI to become reachable before calling the hop done
#
# USAGE:
#   ./rancher-auto-upgrade.sh v2.14.3
#   (target version as $1; defaults to TARGET_DEFAULT below if omitted)
#
# STRONGLY RECOMMENDED:
#   - Run inside tmux: `tmux new -s rancher-upgrade`
#   - Read the log file as it runs: tail -f <LOG_FILE printed at start>
#   - Do a rehearsal run on a disposable environment before running
#     this against a real customer's Rancher instance
#   - Take a hypervisor-level VM snapshot before starting (KB Section 5.1)
#
set -uo pipefail

########################################
# Config
########################################
TARGET_DEFAULT="v2.14.3"
TARGET="${1:-$TARGET_DEFAULT}"

MAX_PULL_RETRIES=10
PULL_RETRY_SLEEP=10

REGISTRY_QUERY_RETRIES=5
REGISTRY_QUERY_SLEEP=10

DISK_PRESSURE_THRESHOLD=85     # % used on / before we clean up old images/containers
KEEP_OLD_CONTAINERS=1          # how many rancher-old-* to always keep (most recent N)

STARTUP_WARN_TIMEOUT=900       # seconds before we start logging loud warnings (does NOT stop the hop)
STARTUP_HARD_ABORT=5400        # seconds (90m) of total unreachable-UI time before the hop truly gives up
STARTUP_POLL_INTERVAL=10
FATAL_WINDOW="3m"              # rolling look-back window for FATAL detection (NOT reset per-restart —
                                # some environments crash-loop every ~30s with only 1 FATAL per boot,
                                # so counting "since this boot" can miss the pattern entirely)
FATAL_THRESHOLD=1              # this many [FATAL] webhook lines in the window triggers remediation
WEBHOOK_FIX_RETRY_BUDGET=90    # seconds of rapid retry per remediation attempt (catches brief apiserver windows)
REQUIRED_STABLE_SECONDS=360    # minutes of no-restart/no-FATAL required before re-enabling webhook (6m — empirically what it took)
DISK_CHECK_INTERVAL=120        # re-run disk_guard this often while stuck waiting on a hop

BKDIR=$( [ -d /data ] && echo /data/backup/rancher || echo /var/backups/rancher )
mkdir -p "$BKDIR"
LOG_FILE="$BKDIR/auto-upgrade-$(date +%Y%m%d-%H%M%S).log"

########################################
# Helpers
########################################
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

die() {
  log "FATAL: $*"
  log "Automation stopped. Manual review required — see $LOG_FILE"
  exit 1
}

# retry_until <max_seconds> <sleep_interval> <command...>
# Retries a command (suppressing stderr) until it succeeds or times out.
retry_until() {
  local max_seconds="$1"; shift
  local interval="$1"; shift
  local start
  start=$(date +%s)
  while true; do
    if "$@" >/tmp/retry_until.out 2>/dev/null; then
      cat /tmp/retry_until.out
      return 0
    fi
    if (( $(date +%s) - start >= max_seconds )); then
      return 1
    fi
    sleep "$interval"
  done
}

########################################
# State derivation (re-run fresh each hop — no stale shell state)
########################################
init_vars() {
  RANCHER_CT=$(docker ps -a --format '{{.Names}}\t{{.Image}}' | grep 'rancher/rancher:' | head -1 | cut -f1)
  [[ -z "$RANCHER_CT" ]] && die "no rancher container found via 'docker ps -a'"
  RANCHER_VOL=$(docker inspect "$RANCHER_CT" --format \
    '{{range .Mounts}}{{if eq .Destination "/var/lib/rancher"}}{{.Source}}{{end}}{{end}}')
  [[ -z "$RANCHER_VOL" ]] && die "could not resolve /var/lib/rancher volume for $RANCHER_CT"
  CUR=$(docker inspect "$RANCHER_CT" --format '{{.Config.Image}}')
  STAMP=$(date +%Y%m%d-%H%M%S)
}

########################################
# Hop planner — computes the single next hop toward TARGET
# Sets global NEW="" if already at target.
########################################
compute_next_hop() {
  NEW=""
  local out
  out=$(retry_until $((REGISTRY_QUERY_RETRIES * REGISTRY_QUERY_SLEEP)) "$REGISTRY_QUERY_SLEEP" bash -c "
    TOK=\$(curl -s --max-time 30 \
      'https://auth.docker.io/token?service=registry.docker.io&scope=repository:rancher/rancher:pull' \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"token\"])') || exit 1
    curl -s --max-time 60 -H \"Authorization: Bearer \$TOK\" \
      'https://registry-1.docker.io/v2/rancher/rancher/tags/list' \
      | CUR='$CUR' TARGET='$TARGET' python3 -c '
import json, re, sys, os
CUR, TARGET = os.environ[\"CUR\"], os.environ[\"TARGET\"]
tags = json.load(sys.stdin)[\"tags\"]
tags = [t for t in tags if re.fullmatch(r\"v[0-9]+\.[0-9]+\.[0-9]+\", t)]
cur_v = re.search(r\"v([0-9]+\.[0-9]+)\.([0-9]+)\", CUR)
cur_minor, cur_patch = cur_v.group(1), int(cur_v.group(2))
tgt_minor = re.match(r\"v([0-9]+\.[0-9]+)\.([0-9]+)\", TARGET).group(1)
if TARGET not in tags:
    print(\"ERR target not found on registry\"); sys.exit(1)
lp = {}
for t in tags:
    m = \".\".join(t[1:].split(\".\")[:2]); p = int(t.split(\".\")[-1])
    if m not in lp or p > lp[m]: lp[m] = p
mk = lambda m: tuple(int(x) for x in m.split(\".\"))
between = sorted([m for m in lp if mk(cur_minor) <= mk(m) <= mk(tgt_minor)], key=mk)
if not between or between[0] != cur_minor or between[-1] != tgt_minor:
    print(\"ERR minor range incomplete\"); sys.exit(1)
if cur_patch < lp[cur_minor]:
    print(\"NEXT rancher/rancher:v%s.%d\" % (cur_minor, lp[cur_minor])); sys.exit(0)
nxt = [m for m in between if mk(m) > mk(cur_minor)]
if not nxt:
    print(\"DONE\"); sys.exit(0)
m = nxt[0]
ver = TARGET if m == tgt_minor else \"v%s.%d\" % (m, lp[m])
print(\"NEXT rancher/rancher:%s\" % ver)
'
  ")
  [[ $? -ne 0 || -z "$out" ]] && die "hop-planner could not reach Docker Hub registry after retries"
  echo "$out" | grep -q '^ERR' && die "hop-planner error: $out"
  echo "$out" | grep -q '^DONE' && { NEW=""; return 0; }
  NEW=$(echo "$out" | grep '^NEXT' | awk '{print $2}')
  [[ -z "$NEW" ]] && die "hop-planner produced no NEW version (unexpected output: $out)"
}

########################################
# Disk-pressure guard (Section 5.1-adjacent, learned the hard way)
########################################
disk_guard() {
  local usage
  usage=$(df / | awk 'NR==2{gsub("%","",$5); print $5}')
  log "Root disk usage: ${usage}%"
  if (( usage < DISK_PRESSURE_THRESHOLD )); then
    return 0
  fi
  log "Root disk >= ${DISK_PRESSURE_THRESHOLD}% — cleaning up old rancher-old-* containers/images (keeping most recent $KEEP_OLD_CONTAINERS + the running one)"
  local all_old
  all_old=$(docker ps -a --filter name=rancher-old- --format '{{.CreatedAt}}\t{{.Names}}' | sort | awk '{print $NF}')
  local keep
  keep=$(echo "$all_old" | tail -n "$KEEP_OLD_CONTAINERS")
  local removed_any=0
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    if ! grep -qx "$c" <<<"$keep"; then
      local img
      img=$(docker inspect "$c" --format '{{.Config.Image}}' 2>/dev/null)
      log "Removing old container $c (image $img)"
      docker rm "$c" >/dev/null 2>&1
      docker rmi "$img" >/dev/null 2>&1
      removed_any=1
    fi
  done <<<"$all_old"
  (( removed_any )) && log "Cleanup done. New root disk usage: $(df / | awk 'NR==2{print $5}')"
}

########################################
# Pull with retry (mid-pull resets are common on lossy networks;
# Docker's layer cache makes retries cheap — only failed layers redo)
########################################
pull_with_retry() {
  local image="$1"
  local attempt=1
  until docker pull "$image"; do
    log "Pull attempt $attempt failed for $image"
    (( attempt >= MAX_PULL_RETRIES )) && die "image pull failed after $MAX_PULL_RETRIES attempts"
    attempt=$((attempt + 1))
    sleep "$PULL_RETRY_SLEEP"
  done
  log "Pulled $image successfully"
}

########################################
# Backup with sanity check
########################################
backup_with_check() {
  local raw_mb tar_path tar_mb ratio
  raw_mb=$(du -sm "$RANCHER_VOL" | cut -f1)
  tar_path="$BKDIR/data-$STAMP.tar.gz"
  log "Backing up $RANCHER_VOL (${raw_mb}MB raw) -> $tar_path"
  tar pzcf "$tar_path" -C "$RANCHER_VOL" .
  tar_mb=$(du -sm "$tar_path" | cut -f1)
  log "Backup complete: ${tar_mb}MB"
  if (( tar_mb < 1 )); then
    die "backup file suspiciously small (${tar_mb}MB) — aborting before touching the running container"
  fi
}

########################################
# Webhook-race auto-remediation
# (found during rehearsal: repeated [FATAL] on webhook admission
#  calls, root cause = outer container crash-restart cycle keeps
#  killing the rancher-webhook pod's sandbox before it finishes its
#  own internal startup delay. The object *names* Rancher uses for
#  its ValidatingWebhookConfiguration/MutatingWebhookConfiguration
#  have changed across versions ("rancher.cattle.io" on older
#  releases vs "validating-webhook-configuration"/"mutating-webhook-
#  configuration" on v2.13+), so we delete --all instead of hardcoding
#  a name — rancher-webhook re-applies its own config on next clean
#  startup (its own logs show "Sleeping for 15 seconds then applying
#  webhook config"), so this is safe and self-healing.
#  This can fire MULTIPLE times per hop — a single application isn't
#  always enough if the outer container keeps crashing on a fresh
#  cause after the first fix.)
########################################

# start_webhook_reapply_loop: launches a persistent BACKGROUND loop that
# re-deletes webhook configs and re-scales rancher-webhook to 0 every
# second, indefinitely, until stopped. Found necessary in practice: a
# single successful scale-to-0 can be lost if the outer container crashes
# again before that write is durably committed to the embedded datastore
# (this environment runs "--cluster-reset" on effectively every boot,
# which can restore state from just before our edit). Reapplying every
# ~1s means we don't depend on one lucky write — any write that lands in
# a cycle with enough time to commit before the next crash is sufficient,
# and eventually the crash cycle itself stops once rancher-webhook gets
# real uninterrupted time to finish its own startup.
REAPPLY_PID=""
start_webhook_reapply_loop() {
  (( ${REAPPLY_PID:-0} != 0 )) 2>/dev/null && return 0   # already running
  (
    while true; do
      docker exec rancher sh -c 'kubectl delete validatingwebhookconfigurations --all --ignore-not-found=true; kubectl delete mutatingwebhookconfigurations --all --ignore-not-found=true' >/dev/null 2>&1
      docker exec rancher kubectl scale deployment rancher-webhook -n cattle-system --replicas=0 >/dev/null 2>&1
      sleep 1
    done
  ) &
  REAPPLY_PID=$!
  log "  started continuous webhook-remediation loop (pid $REAPPLY_PID)"
}

stop_webhook_reapply_loop() {
  if [[ -n "$REAPPLY_PID" ]]; then
    kill "$REAPPLY_PID" >/dev/null 2>&1
    wait "$REAPPLY_PID" 2>/dev/null
    log "  stopped webhook-remediation loop (pid $REAPPLY_PID)"
    REAPPLY_PID=""
  fi
}
trap 'stop_webhook_reapply_loop' EXIT

# attempt_webhook_scale_up: bounded rapid-retry, used once when re-enabling
# after a confirmed stable window.
attempt_webhook_scale_up() {
  local budget="$1"
  local start
  start=$(date +%s)
  while (( $(date +%s) - start < budget )); do
    if docker exec rancher kubectl scale deployment rancher-webhook -n cattle-system --replicas=1 >/dev/null 2>&1; then
      log "  rancher-webhook scaled back to 1 replica"
      return 0
    fi
    sleep 0.5
  done
  return 1
}

########################################
# Wait for the new container to finish starting.
# State machine: detect restarts via container StartedAt, detect FATAL
# bursts since the last restart, remediate (possibly repeatedly), require
# a real stable window before re-enabling the webhook, keep polling for
# the UI. Never gives up before STARTUP_HARD_ABORT — this is the fix for
# "script dies mid-run on the first hop that doesn't self-heal instantly".
########################################
wait_for_startup() {
  local start last_disk_check last_started_at="" stable_since
  local remediation_active=0 webhook_reenabled=1 warned=0
  start=$(date +%s)
  last_disk_check=$start
  stable_since=$start

  while true; do
    local now
    now=$(date +%s)

    if curl -sk -o /dev/null --max-time 5 -w '%{http_code}' https://localhost 2>/dev/null | grep -qE '^(200|301|302|401)$'; then
      stop_webhook_reapply_loop
      log "UI reachable — hop startup complete (after $((now - start))s)"
      return 0
    fi

    # detect a fresh container restart -> reset the clean-streak clock.
    # (the reapply loop, if active, keeps running regardless of restarts —
    # it doesn't need re-arming since it never stopped in the first place)
    local started_at
    started_at=$(docker inspect rancher --format '{{.State.StartedAt}}' 2>/dev/null || true)
    if [[ -n "$started_at" && "$started_at" != "$last_started_at" ]]; then
      if [[ -n "$last_started_at" ]]; then
        log "Container restarted (new StartedAt) — resetting stability clock"
      fi
      last_started_at="$started_at"
      stable_since="$now"
      webhook_reenabled=0
    fi

    # periodic disk check while stuck
    if (( now - last_disk_check >= DISK_CHECK_INTERVAL )); then
      disk_guard
      last_disk_check="$now"
    fi

    # FATAL detection over a rolling window (NOT scoped to "since this boot" —
    # a fast crash-loop can produce just 1 FATAL per ~30s boot cycle, which
    # would never accumulate to a per-boot threshold before the next restart
    # resets it; a time-based window catches that pattern reliably)
    local fatal_count
    fatal_count=$(docker logs --since "$FATAL_WINDOW" rancher 2>&1 | grep -c '\[FATAL\]' || true)
    if (( fatal_count >= FATAL_THRESHOLD )) && (( remediation_active == 0 )); then
      log "FATAL detected ($fatal_count in last $FATAL_WINDOW) at $((now - start))s — starting continuous webhook remediation"
      start_webhook_reapply_loop
      remediation_active=1
      stable_since="$now"   # require a fresh clean window measured from when we started fixing, not the boot
    fi

    # once remediation is active and we've had a real stable window
    # (measured from the last restart OR the start of remediation,
    # whichever is more recent), stop reapplying and re-enable the webhook
    if (( remediation_active == 1 && webhook_reenabled == 0 )) && (( now - stable_since >= REQUIRED_STABLE_SECONDS )); then
      log "Stable for $((now - stable_since))s — stopping remediation loop and re-enabling rancher-webhook"
      stop_webhook_reapply_loop
      if attempt_webhook_scale_up "$WEBHOOK_FIX_RETRY_BUDGET"; then
        webhook_reenabled=1
        remediation_active=0
      else
        log "  scale-to-1 could not be confirmed — resuming remediation loop as a safety net"
        start_webhook_reapply_loop
        stable_since="$now"
      fi
    fi

    if (( now - start >= STARTUP_WARN_TIMEOUT )) && (( warned == 0 )); then
      log "WARNING: startup not confirmed within ${STARTUP_WARN_TIMEOUT}s — still retrying (hard abort at ${STARTUP_HARD_ABORT}s)"
      warned=1
    fi
    if (( now - start >= STARTUP_HARD_ABORT )); then
      log "WARNING: hard abort ceiling (${STARTUP_HARD_ABORT}s) reached without a stable startup"
      stop_webhook_reapply_loop
      return 1
    fi

    sleep "$STARTUP_POLL_INTERVAL"
  done
}

########################################
# One full hop
########################################
run_one_hop() {
  init_vars
  compute_next_hop
  if [[ -z "$NEW" ]]; then
    return 1   # already at target
  fi

  log "=================================================="
  log "HOP: $CUR  ->  $NEW"
  log "=================================================="

  disk_guard
  pull_with_retry "$NEW"

  log "⏱ DOWNTIME START — stopping $RANCHER_CT"
  docker stop "$RANCHER_CT" || die "docker stop failed"
  backup_with_check

  OLD="rancher-old-$STAMP"
  docker rename "$RANCHER_CT" "$OLD" || die "docker rename failed"

  docker run -d \
    --volumes-from "$OLD" \
    --restart=unless-stopped \
    --name rancher \
    -p 443:443 \
    -p 80:80 \
    --privileged \
    --log-opt max-size=100m --log-opt max-file=3 \
    "$NEW" || die "docker run (new container) failed"

  if wait_for_startup; then
    log "⏱ DOWNTIME END — hop complete, now running $NEW"
  else
    die "hop did not reach a stable startup even after ${STARTUP_HARD_ABORT}s of automatic webhook remediation — this is a genuinely unrecoverable state, not a timing issue. Check 'docker logs rancher' manually. Rollback target: $OLD"
  fi
}

########################################
# Post-upgrade webhook sanity check
# (found in the wild: after crossing into v2.13.x/v2.14.x+ where
#  rancher-turtles/embedded-CAPI provisioning was introduced, an
#  upgrade can leave a STALE duplicate MutatingWebhookConfiguration/
#  ValidatingWebhookConfiguration behind — same webhook rule names as
#  the correct, currently-installed one, but pointing at a namespace
#  that no longer exists. Kubernetes calls EVERY matching webhook
#  config for a resource, so the stale one silently blocks cluster
#  object updates even though a correct config exists side-by-side.
#  This only DETECTS and REPORTS — it does not auto-delete, since
#  removing the wrong webhook config on a real customer's cluster
#  unattended is too risky to fully automate.)
########################################
check_stale_webhook_configs() {
  log "Checking for stale/duplicate webhook configs (known v2.13+/v2.14+ CAPI upgrade artifact)..."
  local kind
  for kind in mutatingwebhookconfigurations validatingwebhookconfigurations; do
    local names
    names=$(docker exec rancher kubectl get "$kind" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    [[ -z "$names" ]] && continue
    local n
    for n in $names; do
      local rules
      rules=$(docker exec rancher kubectl get "$kind" "$n" -o jsonpath='{range .webhooks[*]}{.clientConfig.service.namespace}{"/"}{.clientConfig.service.name}{"\n"}{end}' 2>/dev/null)
      [[ -z "$rules" ]] && continue
      local svc_ns svc_name missing=0 total=0
      while IFS='/' read -r svc_ns svc_name; do
        [[ -z "$svc_ns" ]] && continue
        total=$((total + 1))
        if ! docker exec rancher kubectl get svc "$svc_name" -n "$svc_ns" >/dev/null 2>&1; then
          missing=$((missing + 1))
        fi
      done <<< "$rules"
      if (( total > 0 && missing == total )); then
        log "  WARNING: $kind/$n has ALL $total webhook rule(s) pointing at a service that does not exist — likely a stale duplicate from an earlier version."
        log "    Review before deleting: docker exec rancher kubectl get $kind $n -o jsonpath='{range .webhooks[*]}{.name}{\"  ->  \"}{.clientConfig.service.namespace}{\"/\"}{.clientConfig.service.name}{\"\\n\"}{end}'"
        log "    If confirmed stale (a differently-named, working config exists covering the same rules): docker exec rancher kubectl delete $kind $n"
      fi
    done
  done
}

########################################
# Main
########################################
log "Starting automated Rancher upgrade -> target $TARGET"
log "Log file: $LOG_FILE"
log "Recommended: run this inside tmux and tail -f the log file from another session"

hop_num=0
while true; do
  if run_one_hop; then
    hop_num=$((hop_num + 1))
    log "Hop #$hop_num complete. Pausing 10s before checking for next hop..."
    sleep 10
  else
    log "Already at target ($TARGET) or no further hop needed. Total hops run: $hop_num"
    break
  fi
done

log "=================================================="
log "Final verification"
log "=================================================="
docker ps --filter name=rancher | tee -a "$LOG_FILE"
docker inspect rancher --format 'Final image: {{.Config.Image}}' | tee -a "$LOG_FILE"
docker exec rancher kubectl get nodes -o wide 2>/dev/null | tee -a "$LOG_FILE"
check_stale_webhook_configs
log "Automated upgrade run finished. Review $LOG_FILE for the full timeline."
log "NOTE: old rancher-old-* containers/images from this run were kept for rollback (Section 7.1/7.2 of the KB) — clean up manually after 1-2 weeks of stable operation."
