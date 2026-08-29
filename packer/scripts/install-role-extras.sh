#!/usr/bin/env bash
##############################################################################
# install-role-extras.sh — Role-specific packages
##############################################################################
set -euo pipefail

: "${NODE_ROLE:?NODE_ROLE must be set}"
: "${ELK_VERSION:?ELK_VERSION must be set}"
export DEBIAN_FRONTEND=noninteractive

echo "=== Installing role extras for $NODE_ROLE ==="

case "$NODE_ROLE" in
  logstash)
    # Install Logstash plugins (offline-friendly; pre-bundled in plugin dir)
    sudo /usr/share/logstash/bin/logstash-plugin install \
      logstash-input-s3 \
      logstash-input-sqs \
      logstash-input-kinesis \
      logstash-filter-geoip \
      logstash-filter-useragent \
      logstash-output-elasticsearch \
      logstash-output-dead_letter_queue
    ;;

  app-host)
    # Fluentd (td-agent 4.x) for app log tailing
    curl -fsSL https://toolbelt.treasuredata.com/sh/install-ubuntu-jammy-fluent-package5-lts.sh | sudo sh
    sudo systemctl disable fluentd
    # Nginx with extra modules
    sudo apt-get install -y -qq libnginx-mod-http-geoip2 geoipupdate
    ;;

  es-master|es-data|es-ingest|es-coord|kibana)
    # No additional packages; everything ships with ES 8.x
    ;;
esac

echo "=== Role extras installed for $NODE_ROLE ==="
