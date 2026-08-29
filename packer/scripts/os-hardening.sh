#!/usr/bin/env bash
##############################################################################
# os-hardening.sh — CIS-aligned Ubuntu 22.04 hardening baseline
##############################################################################
set -euo pipefail

echo "=== Applying OS hardening ==="

# ── SSH hardening ─────────────────────────────────────────────────────────────
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf > /dev/null <<'EOF'
Protocol 2
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
Banner /etc/ssh/banner
EOF

echo "Authorized use only. All activity is monitored and logged." | \
  sudo tee /etc/ssh/banner

# ── Disable unused filesystems ────────────────────────────────────────────────
sudo tee /etc/modprobe.d/disable-filesystems.conf > /dev/null <<'EOF'
install cramfs /bin/true
install freevxfs /bin/true
install jffs2 /bin/true
install hfs /bin/true
install hfsplus /bin/true
install squashfs /bin/true
install udf /bin/true
EOF

# ── Sysctl hardening ──────────────────────────────────────────────────────────
sudo tee /etc/sysctl.d/99-hardening.conf > /dev/null <<'EOF'
# Network hardening
net.ipv4.ip_forward = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.disable_ipv6 = 1

# Memory
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2

# Elasticsearch requirements
vm.max_map_count = 262144
vm.swappiness = 1
EOF

sudo sysctl --system

# ── Disable swap ──────────────────────────────────────────────────────────────
sudo swapoff -a || true

# ── Auditd ────────────────────────────────────────────────────────────────────
sudo apt-get install -y -qq auditd audispd-plugins
sudo systemctl enable auditd

# ── Fail2ban ──────────────────────────────────────────────────────────────────
sudo apt-get install -y -qq fail2ban

sudo tee /etc/fail2ban/jail.local > /dev/null <<'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port    = ssh
filter  = sshd
logpath = /var/log/auth.log
EOF

sudo systemctl enable fail2ban

# ── Unattended upgrades (security patches only) ───────────────────────────────
sudo apt-get install -y -qq unattended-upgrades

sudo tee /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null <<'EOF'
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF

echo "=== OS hardening complete ==="
