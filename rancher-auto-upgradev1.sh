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
#     rancher-webhook"), scales rancher-webhook to 0 replicas to let
#     the outer container stabilize, then scales back to 1 — this was
#     the clean fix found during rehearsal after whack-a-mole deleting
#     individual webhook configs stopped working reliably
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

STARTUP_TIMEOUT=900            # seconds to wait for UI reachable before declaring the hop stuck
STARTUP_POLL_INTERVAL=10
FATAL_WEBHOOK_WINDOW="3m"      # look-back window when scanning logs for repeated webhook FATALs
FATAL_WEBHOOK_THRESHOLD=2      # this many FATAL webhook hits in the window triggers auto-fix
WEBHOOK_STABILIZE_WAIT=60      # seconds to let the outer container settle after scaling webhook to 0

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
# (found during rehearsal: repeated [FATAL] on different webhook
#  rules, root cause = outer container crash-restart cycle keeps
#  killing the rancher-webhook pod's sandbox before it finishes its
#  own internal startup delay. Deleting individual webhook configs
#  is whack-a-mole; scaling webhook to 0 replicas breaks the cycle
#  cleanly by removing it from the blast radius entirely.)
########################################
fix_webhook_deadlock() {
  log "Detected repeated webhook-race FATAL — applying scale-to-0 remediation"
  retry_until 60 0.5 docker exec rancher kubectl delete validatingwebhookconfiguration rancher.cattle.io \
    || log "  (validatingwebhookconfiguration delete: not found or already clear, continuing)"
  retry_until 60 0.5 docker exec rancher kubectl delete mutatingwebhookconfiguration rancher.cattle.io \
    || log "  (mutatingwebhookconfiguration delete: not found or already clear, continuing)"
  retry_until 60 0.5 docker exec rancher kubectl scale deployment rancher-webhook -n cattle-system --replicas=0 \
    || log "  (scale-to-0: could not confirm, continuing anyway)"
  log "Waiting ${WEBHOOK_STABILIZE_WAIT}s for outer container to stabilize before re-enabling webhook..."
  sleep "$WEBHOOK_STABILIZE_WAIT"
  retry_until 60 0.5 docker exec rancher kubectl scale deployment rancher-webhook -n cattle-system --replicas=1 \
    || log "  (scale-to-1: could not confirm, will rely on startup-wait loop to keep checking)"
}

########################################
# Wait for the new container to finish starting
########################################
wait_for_startup() {
  local start already_fixed=0
  start=$(date +%s)
  while true; do
    if curl -sk -o /dev/null --max-time 5 -w '%{http_code}' https://localhost 2>/dev/null | grep -qE '^(200|301|302|401)$'; then
      log "UI reachable — hop startup complete"
      return 0
    fi

    local fatal_count
    fatal_count=$(docker logs --since "$FATAL_WEBHOOK_WINDOW" rancher 2>&1 | grep -c '\[FATAL\].*webhook' || true)
    if (( fatal_count >= FATAL_WEBHOOK_THRESHOLD )) && (( already_fixed == 0 )); then
      fix_webhook_deadlock
      already_fixed=1
    fi

    if (( $(date +%s) - start >= STARTUP_TIMEOUT )); then
      log "WARNING: startup not confirmed within ${STARTUP_TIMEOUT}s"
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
    die "hop did not confirm healthy startup within timeout — check 'docker logs rancher' manually. Rollback target: $OLD"
  fi
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
log "Automated upgrade run finished. Review $LOG_FILE for the full timeline."
log "NOTE: old rancher-old-* containers/images from this run were kept for rollback (Section 7.1/7.2 of the KB) — clean up manually after 1-2 weeks of stable operation."
