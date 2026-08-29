#!/usr/bin/env bash
##############################################################################
# install-elastic.sh — Installs Elasticsearch, Kibana, or Logstash
# based on NODE_ROLE environment variable.
##############################################################################
set -euo pipefail

: "${ELK_VERSION:?ELK_VERSION must be set}"
: "${NODE_ROLE:?NODE_ROLE must be set}"

export DEBIAN_FRONTEND=noninteractive

echo "=== Installing Elastic components for role: $NODE_ROLE, version: $ELK_VERSION ==="

# Add Elastic GPG key and repo
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | \
  sudo gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] \
  https://artifacts.elastic.co/packages/8.x/apt stable main" | \
  sudo tee /etc/apt/sources.list.d/elastic-8.x.list

sudo apt-get update -qq

case "$NODE_ROLE" in
  es-master|es-data|es-ingest|es-coord)
    echo "Installing elasticsearch=${ELK_VERSION}..."
    sudo apt-get install -y -qq "elasticsearch=${ELK_VERSION}"

    # Pre-create dirs with correct ownership
    sudo mkdir -p /var/lib/elasticsearch /var/log/elasticsearch /etc/elasticsearch/certs
    sudo chown -R elasticsearch:elasticsearch \
      /var/lib/elasticsearch /var/log/elasticsearch /etc/elasticsearch/certs
    sudo chmod 750 /var/lib/elasticsearch /var/log/elasticsearch
    sudo chmod 750 /etc/elasticsearch/certs

    # Disable auto-start; bootstrap fills config
    sudo systemctl disable elasticsearch
    ;;

  kibana)
    echo "Installing kibana=${ELK_VERSION}..."
    sudo apt-get install -y -qq "kibana=${ELK_VERSION}"
    sudo mkdir -p /etc/kibana/certs
    sudo chown -R kibana:kibana /etc/kibana/certs
    sudo chmod 750 /etc/kibana/certs
    sudo systemctl disable kibana
    ;;

  logstash)
    echo "Installing logstash=1:${ELK_VERSION}-1..."
    sudo apt-get install -y -qq "logstash=1:${ELK_VERSION}-1"
    sudo mkdir -p /etc/logstash/certs /var/lib/logstash/queue
    sudo chown -R logstash:logstash /etc/logstash/certs /var/lib/logstash
    sudo chmod 750 /etc/logstash/certs
    sudo systemctl disable logstash
    ;;

  app-host)
    echo "Installing nginx and Filebeat for app-host..."
    sudo apt-get install -y -qq nginx
    sudo apt-get install -y -qq "filebeat=${ELK_VERSION}"
    sudo systemctl disable nginx filebeat
    ;;
esac

echo "=== Elastic installation complete for $NODE_ROLE ==="
