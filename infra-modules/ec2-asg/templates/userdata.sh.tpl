#!/usr/bin/env bash
##############################################################################
# ELK Node Bootstrap Script
# Rendered by Terraform templatefile(); variables injected at provisioning.
##############################################################################
set -euo pipefail

NODE_ROLE="${node_role}"
ENVIRONMENT="${environment}"
ELK_VERSION="${elk_version}"
SSM_PREFIX="${ssm_path_prefix}"
CLUSTER_NAME="${cluster_name}"
NODE_NAME_PREFIX="${node_name_prefix}"
ES_HEAP="${es_heap_size}"
DATA_DEVICE="${data_volume_device}"
DATA_MOUNT="${data_volume_mount}"
AWS_REGION="${aws_region}"
TLS_MODE="${tls_mode}"

# ── Instance identity ─────────────────────────────────────────────────────────
INSTANCE_ID=$(TOKEN=$(curl -s -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
  http://169.254.169.254/latest/api/token) && \
  curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(TOKEN=$(curl -s -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
  http://169.254.169.254/latest/api/token) && \
  curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)
NODE_NAME="$${NODE_NAME_PREFIX}-$${INSTANCE_ID}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$NODE_ROLE] $*" | tee -a /var/log/elk-bootstrap.log; }

log "=== ELK Bootstrap starting. Role=$NODE_ROLE, Env=$ENVIRONMENT, Version=$ELK_VERSION ==="

# ── OS hardening ──────────────────────────────────────────────────────────────
log "Applying OS hardening..."

# Disable swap
swapoff -a
sed -i '/\bswap\b/d' /etc/fstab

# Elasticsearch sysctl requirements
cat >> /etc/sysctl.d/99-elasticsearch.conf <<EOF
vm.max_map_count = 262144
vm.swappiness = 1
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
EOF
sysctl --system

# File descriptor limits
cat >> /etc/security/limits.d/99-elasticsearch.conf <<EOF
elasticsearch  soft  nofile  65535
elasticsearch  hard  nofile  65535
elasticsearch  soft  nproc   4096
elasticsearch  hard  nproc   4096
elasticsearch  soft  memlock unlimited
elasticsearch  hard  memlock unlimited
root           soft  nofile  65535
root           hard  nofile  65535
EOF

# ── Data volume setup ─────────────────────────────────────────────────────────
if [ -n "$DATA_DEVICE" ] && [ "$DATA_DEVICE" != "" ]; then
  log "Setting up data volume $DATA_DEVICE → $DATA_MOUNT"

  # Wait for device
  for i in $(seq 1 30); do
    [ -b "$DATA_DEVICE" ] && break
    log "Waiting for device $DATA_DEVICE ($i/30)..."
    sleep 5
  done

  if ! blkid "$DATA_DEVICE" | grep -q ext4; then
    log "Formatting $DATA_DEVICE as ext4..."
    mkfs.ext4 -F -L elk-data "$DATA_DEVICE"
  fi

  mkdir -p "$DATA_MOUNT"
  echo "LABEL=elk-data  $DATA_MOUNT  ext4  defaults,noatime,nodiratime  0 2" >> /etc/fstab
  mount -a
  log "Data volume mounted at $DATA_MOUNT"
fi

# ── Fetch TLS materials from SSM ──────────────────────────────────────────────
log "Fetching TLS materials from SSM..."
mkdir -p /etc/elasticsearch/certs
chmod 750 /etc/elasticsearch/certs

fetch_ssm() {
  local param="$1"
  local dest="$2"
  aws ssm get-parameter \
    --name "$SSM_PREFIX/certs/$param" \
    --with-decryption \
    --region "$AWS_REGION" \
    --query Parameter.Value \
    --output text > "$dest"
  chmod 640 "$dest"
}

fetch_ssm "ca.crt"              /etc/elasticsearch/certs/ca.crt
fetch_ssm "$NODE_ROLE/node.crt" /etc/elasticsearch/certs/node.crt
fetch_ssm "$NODE_ROLE/node.key" /etc/elasticsearch/certs/node.key
chown -R elasticsearch:elasticsearch /etc/elasticsearch/certs

# ── Fetch cluster bootstrap credentials ──────────────────────────────────────
ELASTIC_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "$SSM_PREFIX/$ENVIRONMENT/elastic-password" \
  --query SecretString --output text --region "$AWS_REGION" | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

# ── Configure elasticsearch.yml (role-specific; base template) ────────────────
log "Writing elasticsearch.yml for role=$NODE_ROLE..."
cat > /etc/elasticsearch/elasticsearch.yml <<ESCONF
$(aws ssm get-parameter \
  --name "$SSM_PREFIX/$ENVIRONMENT/configs/elasticsearch-$NODE_ROLE.yml" \
  --with-decryption \
  --region "$AWS_REGION" \
  --query Parameter.Value \
  --output text)
# Runtime overrides injected by bootstrap
node.name: "$NODE_NAME"
ESCONF

# ── Configure JVM heap ────────────────────────────────────────────────────────
log "Setting JVM heap to $ES_HEAP..."
cat > /etc/elasticsearch/jvm.options.d/heap.options <<EOF
-Xms$${ES_HEAP}
-Xmx$${ES_HEAP}
EOF

# ── Extra role-specific userdata ──────────────────────────────────────────────
${extra_userdata}

# ── Start services ────────────────────────────────────────────────────────────
log "Enabling and starting services for role=$NODE_ROLE..."

case "$NODE_ROLE" in
  es-master|es-data-hot|es-data-warm|es-ingest|es-coord)
    systemctl enable elasticsearch
    systemctl start elasticsearch
    ;;
  kibana)
    systemctl enable kibana
    systemctl start kibana
    ;;
  logstash)
    systemctl enable logstash
    systemctl start logstash
    ;;
  app-host)
    systemctl enable nginx filebeat fluent-bit
    systemctl start nginx filebeat fluent-bit
    ;;
esac

# Metricbeat runs on all nodes
systemctl enable metricbeat
systemctl start metricbeat

log "=== Bootstrap complete for $NODE_NAME ==="
