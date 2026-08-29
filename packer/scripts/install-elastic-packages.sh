#!/usr/bin/env bash
##############################################################################
# Installs Elastic stack packages based on NODE_ROLE environment variable.
# Supports apt (Ubuntu/Debian) and dnf (Amazon Linux 2023 / Rocky Linux 9).
##############################################################################
set -euo pipefail

PKG_MGR=$(command -v apt-get &>/dev/null && echo "apt" || echo "dnf")
VERSION="${ELK_VERSION:-8.12.2}"

install_apt() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

install_dnf() {
  dnf install -y "$@"
}

install_pkg() {
  if [ "$PKG_MGR" = "apt" ]; then
    install_apt "$@"
  else
    install_dnf "$@"
  fi
}

echo "Installing Elastic packages for role: $NODE_ROLE (version: $VERSION)"

case "$NODE_ROLE" in
  es-master|es-data-hot|es-data-warm|es-ingest|es-coord)
    if [ "$PKG_MGR" = "apt" ]; then
      install_pkg "elasticsearch=$VERSION"
    else
      install_pkg "elasticsearch-$VERSION"
    fi
    # Metricbeat for stack monitoring
    if [ "$PKG_MGR" = "apt" ]; then
      install_pkg "metricbeat=$VERSION"
    else
      install_pkg "metricbeat-$VERSION"
    fi
    # Filebeat for node log collection
    if [ "$PKG_MGR" = "apt" ]; then
      install_pkg "filebeat=$VERSION"
    else
      install_pkg "filebeat-$VERSION"
    fi
    # Hold version to prevent unintended upgrades
    if [ "$PKG_MGR" = "apt" ]; then
      apt-mark hold elasticsearch metricbeat filebeat
    fi
    ;;

  kibana)
    if [ "$PKG_MGR" = "apt" ]; then
      install_pkg "kibana=$VERSION" "metricbeat=$VERSION" "filebeat=$VERSION"
      apt-mark hold kibana metricbeat filebeat
    else
      install_pkg "kibana-$VERSION" "metricbeat-$VERSION" "filebeat-$VERSION"
    fi
    ;;

  logstash)
    if [ "$PKG_MGR" = "apt" ]; then
      install_pkg "logstash=1:$VERSION-1" "metricbeat=$VERSION" "filebeat=$VERSION"
      apt-mark hold logstash metricbeat filebeat
    else
      install_pkg "logstash-$VERSION" "metricbeat-$VERSION" "filebeat-$VERSION"
    fi
    # Install Logstash plugins
    /usr/share/logstash/bin/logstash-plugin install \
      logstash-input-s3 \
      logstash-input-kinesis \
      logstash-input-sqs \
      logstash-filter-geoip \
      logstash-filter-useragent \
      logstash-output-elasticsearch \
      logstash-output-s3
    ;;

  app-host)
    # Nginx + Filebeat + Metricbeat
    install_pkg nginx
    if [ "$PKG_MGR" = "apt" ]; then
      install_pkg "filebeat=$VERSION" "metricbeat=$VERSION"
      apt-mark hold filebeat metricbeat
    else
      install_pkg "filebeat-$VERSION" "metricbeat-$VERSION"
    fi
    ;;
esac

echo "Package installation complete for $NODE_ROLE"
