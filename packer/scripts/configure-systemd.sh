#!/usr/bin/env bash
##############################################################################
# configure-systemd.sh — Drop-in systemd overrides for ELK services
##############################################################################
set -euo pipefail

: "${NODE_ROLE:?NODE_ROLE must be set}"

configure_service() {
  local svc="$1"
  local limit_mem="$2"

  sudo mkdir -p "/etc/systemd/system/${svc}.service.d"
  sudo tee "/etc/systemd/system/${svc}.service.d/override.conf" > /dev/null <<EOF
[Service]
LimitNOFILE=65535
LimitNPROC=4096
LimitMEMLOCK=infinity
TimeoutStartSec=300
TimeoutStopSec=300
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
EOF
}

case "$NODE_ROLE" in
  es-master|es-data|es-ingest|es-coord)
    configure_service elasticsearch unlimited
    ;;
  kibana)
    configure_service kibana ""
    ;;
  logstash)
    configure_service logstash unlimited
    ;;
  app-host)
    configure_service nginx ""
    configure_service filebeat ""
    configure_service fluentd ""
    ;;
esac

# Metricbeat on all nodes
configure_service metricbeat ""
configure_service filebeat ""

sudo systemctl daemon-reload
echo "=== systemd configuration complete ==="
