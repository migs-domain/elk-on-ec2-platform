#!/usr/bin/env bash
##############################################################################
# TLS Certificate Generation and Distribution Script
# Generates internal CA, per-node certs, and client certs for shippers.
# Outputs are stored in AWS SSM Parameter Store (encrypted).
##############################################################################
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-2}"
SSM_PREFIX="${SSM_PREFIX:-/elk/dev}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
CLUSTER_NAME="${CLUSTER_NAME:-elk-cluster}"
ELASTIC_VERSION="${ELASTIC_VERSION:-8.12.2}"
TMP_DIR=$(mktemp -d)

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# ── Check elasticsearch-certutil is available ─────────────────────────────────
CERTUTIL="/usr/share/elasticsearch/bin/elasticsearch-certutil"
if ! command -v "$CERTUTIL" &>/dev/null && [ ! -f "$CERTUTIL" ]; then
  # Try Docker fallback
  CERTUTIL="docker run --rm -v ${TMP_DIR}:/certs \
    docker.elastic.co/elasticsearch/elasticsearch:${ELASTIC_VERSION} \
    elasticsearch-certutil"
fi

log "=== Generating ELK TLS certificates for: $CLUSTER_NAME ($ENVIRONMENT) ==="

cd "$TMP_DIR"

# ── 1. Generate CA ─────────────────────────────────────────────────────────────
log "Generating CA..."
$CERTUTIL ca \
  --pass "" \
  --out "${TMP_DIR}/elastic-stack-ca.p12" \
  --silent

# Extract PEM for compatibility with non-Java clients
openssl pkcs12 -in "${TMP_DIR}/elastic-stack-ca.p12" \
  -nokeys -passin pass: -out "${TMP_DIR}/ca.crt"

openssl pkcs12 -in "${TMP_DIR}/elastic-stack-ca.p12" \
  -nocerts -nodes -passin pass: -out "${TMP_DIR}/ca.key"

# ── 2. Generate per-node certs (transport + HTTP) ─────────────────────────────
log "Generating node certificates..."

cat > "${TMP_DIR}/instances.yml" <<EOF
instances:
  - name: es-master
    dns:
      - "es-master.${CLUSTER_NAME}.internal"
      - "localhost"
    ip:
      - "127.0.0.1"
  - name: es-data
    dns:
      - "es-data.${CLUSTER_NAME}.internal"
      - "localhost"
    ip:
      - "127.0.0.1"
  - name: es-ingest
    dns:
      - "es-ingest.${CLUSTER_NAME}.internal"
      - "localhost"
    ip:
      - "127.0.0.1"
  - name: es-coord
    dns:
      - "es-coord.${CLUSTER_NAME}.internal"
      - "localhost"
    ip:
      - "127.0.0.1"
  - name: kibana
    dns:
      - "kibana.${CLUSTER_NAME}.internal"
      - "localhost"
    ip:
      - "127.0.0.1"
  - name: logstash
    dns:
      - "logstash.${CLUSTER_NAME}.internal"
      - "localhost"
    ip:
      - "127.0.0.1"
  - name: filebeat
    dns:
      - "filebeat.${CLUSTER_NAME}.internal"
  - name: fluentd
    dns:
      - "fluentd.${CLUSTER_NAME}.internal"
  - name: metricbeat
    dns:
      - "metricbeat.${CLUSTER_NAME}.internal"
EOF

$CERTUTIL cert \
  --ca "${TMP_DIR}/elastic-stack-ca.p12" \
  --ca-pass "" \
  --in "${TMP_DIR}/instances.yml" \
  --out "${TMP_DIR}/certs.zip" \
  --pass "" \
  --silent

unzip -q "${TMP_DIR}/certs.zip" -d "${TMP_DIR}/certs/"

# ── 3. Store in SSM Parameter Store ──────────────────────────────────────────
log "Uploading certificates to SSM..."

upload_cert() {
  local name="$1"
  local file="$2"
  local type="${3:-SecureString}"

  log "  Uploading $name → $SSM_PREFIX/certs/$name"
  aws ssm put-parameter \
    --name "$SSM_PREFIX/certs/$name" \
    --value "$(cat "$file")" \
    --type "$type" \
    --overwrite \
    --region "$AWS_REGION" \
    --no-cli-pager
}

# CA
upload_cert "ca.crt" "${TMP_DIR}/ca.crt" SecureString
upload_cert "ca.key" "${TMP_DIR}/ca.key" SecureString

# Per-node certs
for role in es-master es-data es-ingest es-coord kibana logstash filebeat fluentd metricbeat; do
  cert_dir="${TMP_DIR}/certs/${role}"
  if [ -d "$cert_dir" ]; then
    upload_cert "${role}/node.crt" "${cert_dir}/${role}.crt" SecureString
    upload_cert "${role}/node.key" "${cert_dir}/${role}.key" SecureString
    # Also store as PKCS12 for Java clients
    if [ -f "${cert_dir}/${role}.p12" ]; then
      # Store p12 as base64
      base64 "${cert_dir}/${role}.p12" > "${TMP_DIR}/${role}.p12.b64"
      upload_cert "${role}/node.p12.b64" "${TMP_DIR}/${role}.p12.b64" SecureString
    fi
  fi
done

# CA PKCS12 for Java clients
base64 "${TMP_DIR}/elastic-stack-ca.p12" > "${TMP_DIR}/ca.p12.b64"
upload_cert "ca.p12.b64" "${TMP_DIR}/ca.p12.b64" SecureString

log "=== Certificate generation and upload complete! ==="
log ""
log "Summary:"
log "  CA cert:       $SSM_PREFIX/certs/ca.crt"
log "  CA key:        $SSM_PREFIX/certs/ca.key (SENSITIVE)"
log "  Node certs:    $SSM_PREFIX/certs/<role>/node.{crt,key,p12.b64}"
log ""
log "To renew certificates, re-run this script with the same SSM prefix."
log "Nodes will pick up new certs on next restart."
