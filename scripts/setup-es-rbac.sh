#!/usr/bin/env bash
##############################################################################
# scripts/setup-es-rbac.sh
# Creates Elasticsearch users and roles for all shippers.
# Run after initial cluster bootstrap on the ingest node.
##############################################################################
set -euo pipefail

ES_HOST="${ES_HOST:-https://localhost:9200}"
ELASTIC_PASSWORD="${ELASTIC_PASSWORD:?Set ELASTIC_PASSWORD}"
CA_CERT="${CA_CERT:-/etc/elasticsearch/certs/ca.crt}"

es_api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"

  if [ -n "$body" ]; then
    curl -sk -u "elastic:${ELASTIC_PASSWORD}" \
      -X "$method" \
      -H "Content-Type: application/json" \
      --cacert "$CA_CERT" \
      "${ES_HOST}${path}" \
      -d "$body"
  else
    curl -sk -u "elastic:${ELASTIC_PASSWORD}" \
      -X "$method" \
      --cacert "$CA_CERT" \
      "${ES_HOST}${path}"
  fi
  echo
}

echo "=== Setting up Elasticsearch RBAC ==="

# ── Role: filebeat_writer ──────────────────────────────────────────────────────
echo "Creating filebeat_writer role..."
es_api PUT "/_security/role/filebeat_writer" '{
  "cluster": ["monitor", "manage_ilm", "manage_index_templates"],
  "indices": [
    {
      "names": ["filebeat-*", "logs-system.*", "logs-nginx.*"],
      "privileges": ["create_doc", "create_index", "manage", "auto_configure"]
    }
  ]
}'

es_api POST "/_security/user/filebeat_writer" '{
  "password": "'"${FILEBEAT_PASSWORD:?Set FILEBEAT_PASSWORD}"'",
  "roles": ["filebeat_writer"],
  "full_name": "Filebeat Writer Service Account",
  "email": "elk-ops@acme.com"
}'

# ── Role: logstash_writer ─────────────────────────────────────────────────────
echo "Creating logstash_writer role..."
es_api PUT "/_security/role/logstash_writer" '{
  "cluster": ["monitor", "manage_ilm", "manage_index_templates"],
  "indices": [
    {
      "names": ["logs-aws.*", "logs-logstash.*"],
      "privileges": ["create_doc", "create_index", "manage", "auto_configure", "write"]
    }
  ]
}'

es_api POST "/_security/user/logstash_writer" '{
  "password": "'"${LOGSTASH_PASSWORD:?Set LOGSTASH_PASSWORD}"'",
  "roles": ["logstash_writer"],
  "full_name": "Logstash Writer Service Account"
}'

# ── Role: fluentd_writer ──────────────────────────────────────────────────────
echo "Creating fluentd_writer role..."
es_api PUT "/_security/role/fluentd_writer" '{
  "cluster": ["monitor", "manage_ilm"],
  "indices": [
    {
      "names": ["logs-app.*"],
      "privileges": ["create_doc", "create_index", "manage", "auto_configure"]
    }
  ]
}'

es_api POST "/_security/user/fluentd_writer" '{
  "password": "'"${FLUENTD_PASSWORD:?Set FLUENTD_PASSWORD}"'",
  "roles": ["fluentd_writer"],
  "full_name": "Fluentd Writer Service Account"
}'

# ── Role: remote_monitoring_user ──────────────────────────────────────────────
echo "Creating metricbeat monitoring user..."
es_api POST "/_security/user/metricbeat_monitoring" '{
  "password": "'"${METRICBEAT_PASSWORD:?Set METRICBEAT_PASSWORD}"'",
  "roles": ["remote_monitoring_user", "kibana_system"],
  "full_name": "Metricbeat Stack Monitoring Service Account"
}'

# ── Kibana system user password ───────────────────────────────────────────────
echo "Setting kibana_system user password..."
es_api POST "/_security/user/kibana_system/_password" '{
  "password": "'"${KIBANA_SYSTEM_PASSWORD:?Set KIBANA_SYSTEM_PASSWORD}"'"
}'

echo ""
echo "=== RBAC setup complete! Users created: ==="
echo "  filebeat_writer   — role: filebeat_writer"
echo "  logstash_writer   — role: logstash_writer"
echo "  fluentd_writer    — role: fluentd_writer"
echo "  metricbeat_monitoring — roles: remote_monitoring_user, kibana_system"
echo ""
echo "Store all passwords in AWS Secrets Manager under /elk/<env>/"
