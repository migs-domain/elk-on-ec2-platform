#!/usr/bin/env bash
##############################################################################
# scripts/verify-snapshot.sh
# Verifies the latest SLM snapshot succeeded; intended as a cron job.
# Cron: 0 3 * * * /opt/elk/scripts/verify-snapshot.sh >> /var/log/elk-snapshot-check.log 2>&1
##############################################################################
set -euo pipefail

ES_HOST="${ES_HOST:-https://localhost:9200}"
ELASTIC_PASSWORD="${ELASTIC_PASSWORD:?Set ELASTIC_PASSWORD}"
CA_CERT="${CA_CERT:-/etc/elasticsearch/certs/ca.crt}"
REPOSITORY="${REPOSITORY:-s3_repository}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-26}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
alert() {
  log "ALERT: $*"
  if [ -n "$SLACK_WEBHOOK" ]; then
    curl -s -X POST "$SLACK_WEBHOOK" \
      -H "Content-type: application/json" \
      -d "{\"text\":\":red_circle: *ELK Snapshot Alert*\\n$*\"}" || true
  fi
}

log "=== Checking latest snapshot in repository: $REPOSITORY ==="

# Get latest snapshot
LATEST=$(curl -sk -u "elastic:${ELASTIC_PASSWORD}" \
  --cacert "$CA_CERT" \
  "${ES_HOST}/_cat/snapshots/${REPOSITORY}?format=json&s=end_epoch:desc" | \
  python3 -c "import sys,json; snaps=json.load(sys.stdin); print(json.dumps(snaps[0])) if snaps else print('{}')")

if [ -z "$LATEST" ] || [ "$LATEST" = "{}" ]; then
  alert "No snapshots found in repository $REPOSITORY!"
  exit 1
fi

SNAP_ID=$(echo "$LATEST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id','unknown'))")
SNAP_STATE=$(echo "$LATEST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','UNKNOWN'))")
SNAP_END=$(echo "$LATEST" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('end_epoch','0'))")

log "Latest snapshot: $SNAP_ID | Status: $SNAP_STATE | End: $SNAP_END"

if [ "$SNAP_STATE" != "SUCCESS" ]; then
  alert "Latest snapshot $SNAP_ID is in state $SNAP_STATE (not SUCCESS)!"
  exit 1
fi

# Check age
NOW_EPOCH=$(date +%s)
SNAP_END_SECS="${SNAP_END%%.*}"
AGE_HOURS=$(( (NOW_EPOCH - SNAP_END_SECS) / 3600 ))

log "Snapshot age: ${AGE_HOURS}h (threshold: ${MAX_AGE_HOURS}h)"

if [ "$AGE_HOURS" -gt "$MAX_AGE_HOURS" ]; then
  alert "Latest snapshot $SNAP_ID is ${AGE_HOURS}h old (threshold: ${MAX_AGE_HOURS}h). Daily snapshot may have missed!"
  exit 1
fi

log "=== Snapshot check PASSED: $SNAP_ID is healthy and ${AGE_HOURS}h old ==="
