#!/usr/bin/env bash
###############################################################################
# AEN Testnet — VPS Provisioning Script
# Target: Ubuntu 22.04 / 24.04 LTS (fresh server)
# Run as: root (or via sudo)
#
# What this does:
#   1. System update + base hardening (ufw, fail2ban, unattended-upgrades)
#   2. Creates a dedicated non-root 'aen' service user
#   3. Installs Nginx + Certbot (for the dashboard / API gateway front door)
#   4. Installs Rust toolchain (for the AEN core node / consensus module)
#   5. Installs Docker + Compose (for Prometheus/Grafana + supporting services)
#   6. Opens only the ports AEN actually needs
###############################################################################
set -euo pipefail

AEN_USER="aen"
AEN_HOME="/opt/aen"
P2P_PORT="30333"      # AEN core node P2P gossip port — change if your build differs
RPC_PORT="9944"       # AEN core node local RPC (kept internal, not opened publicly)
HTTP_PORT="80"
HTTPS_PORT="443"

echo "==> [1/7] Updating system packages..."
apt-get update -y
apt-get upgrade -y
apt-get install -y curl wget git ufw fail2ban unattended-upgrades \
                    build-essential pkg-config libssl-dev ca-certificates gnupg lsb-release

echo "==> [2/7] Enabling automatic security updates..."
dpkg-reconfigure -f noninteractive unattended-upgrades

echo "==> [3/7] Creating dedicated service user '${AEN_USER}'..."
if ! id -u "${AEN_USER}" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "${AEN_HOME}" --shell /bin/bash "${AEN_USER}"
fi
mkdir -p "${AEN_HOME}"/{bin,data,logs,config}
chown -R "${AEN_USER}:${AEN_USER}" "${AEN_HOME}"

echo "==> [4/7] Configuring firewall (ufw)..."
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow ${HTTP_PORT}/tcp
ufw allow ${HTTPS_PORT}/tcp
ufw allow ${P2P_PORT}/tcp     # P2P gossip — needs to be reachable by other validator nodes
# NOTE: RPC_PORT (${RPC_PORT}) is intentionally NOT opened publicly.
# Bind RPC to 127.0.0.1 in the node config and proxy it through Nginx if you
# need external API access, with auth in front of it.
ufw --force enable
ufw status verbose

echo "==> [5/7] Installing Nginx + Certbot..."
apt-get install -y nginx certbot python3-certbot-nginx
systemctl enable nginx

echo "==> [6/7] Installing Rust toolchain (for AEN core node build)..."
if ! command -v rustc >/dev/null 2>&1; then
  su - "${AEN_USER}" -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
fi
su - "${AEN_USER}" -c 'source $HOME/.cargo/env && rustc --version && cargo --version'

echo "==> [7/7] Installing Docker + Compose plugin (Prometheus/Grafana stack)..."
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
usermod -aG docker "${AEN_USER}"

echo ""
echo "=============================================================="
echo " Provisioning complete."
echo "   Service user : ${AEN_USER}"
echo "   Home dir     : ${AEN_HOME}"
echo "   Open ports   : 22 (SSH), 80, 443, ${P2P_PORT} (P2P)"
echo "   RPC port ${RPC_PORT} is closed to the public — proxy via Nginx if needed."
echo ""
echo " Next: run 02_deploy_dashboard.sh to publish the AEN Explorer dashboard,"
echo " then 03_deploy_node.sh once your core node binary is built."
echo "=============================================================="
