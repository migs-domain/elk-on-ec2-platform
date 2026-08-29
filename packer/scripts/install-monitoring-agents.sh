#!/usr/bin/env bash
##############################################################################
# install-monitoring-agents.sh — Metricbeat + Filebeat on every node
##############################################################################
set -euo pipefail

: "${ELK_VERSION:?ELK_VERSION must be set}"
export DEBIAN_FRONTEND=noninteractive

echo "=== Installing monitoring agents (Metricbeat, Filebeat) ==="

sudo apt-get install -y -qq \
  "metricbeat=${ELK_VERSION}" \
  "filebeat=${ELK_VERSION}"

sudo systemctl disable metricbeat filebeat

echo "=== Monitoring agents installed ==="
