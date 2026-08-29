#!/usr/bin/env bash
##############################################################################
# Install Fluentd (Fluent Bit) for lightweight log forwarding.
# All roles get fluent-bit installed; app-host role uses it actively.
##############################################################################
set -euo pipefail

PKG_MGR=$(command -v apt-get &>/dev/null && echo "apt" || echo "dnf")

if [ "$PKG_MGR" = "apt" ]; then
  curl -fsSL https://packages.fluentbit.io/fluentbit.key | \
    gpg --dearmor -o /usr/share/keyrings/fluentbit-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/fluentbit-keyring.gpg] https://packages.fluentbit.io/ubuntu/jammy jammy main" \
    > /etc/apt/sources.list.d/fluentbit.list
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y fluent-bit
else
  curl -fsSL https://packages.fluentbit.io/fluentbit.key > /tmp/fluentbit.key
  rpm --import /tmp/fluentbit.key
  cat > /etc/yum.repos.d/fluentbit.repo << 'EOF'
[fluentbit]
name=Fluent Bit
baseurl=https://packages.fluentbit.io/centos/9
gpgcheck=1
gpgkey=https://packages.fluentbit.io/fluentbit.key
enabled=1
EOF
  dnf install -y fluent-bit
fi

# Enable but do not start (configured at runtime)
systemctl enable fluent-bit
echo "Fluent Bit installed and enabled."
