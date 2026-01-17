#!/bin/bash

################################################################################
# DNSTT + V2Ray/Xray Setup - Final Fixed Version
################################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

echo -e "${GREEN}"
cat << "EOF"
╔═════════════════════════════════════════════════════════╗
║  DNSTT + Xray VLESS-Reality Setup                      ║
╚═════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

[[ $EUID -ne 0 ]] && error "Run as root"

# Check dnstt
if ! systemctl is-active --quiet dnstt-server; then
    error "dnstt-server not running"
fi
log "✓ dnstt running"

# Check SOCKS5
if ! systemctl is-active --quiet danted; then
    error "SOCKS5 not running. Run the first script to configure it."
fi
log "✓ SOCKS5 running"

echo ""
info "=== Configuration ==="
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
UUID=$(cat /proc/sys/kernel/random/uuid)

echo "Server IP: $SERVER_IP"
echo "UUID: $UUID"
read -p "Port (default 443): " PORT
PORT=${PORT:-443}
read -p "Proxy name (default MyProxy): " PROXY_NAME
PROXY_NAME=${PROXY_NAME:-MyProxy}

echo ""
log "=== Installing Xray ==="
if ! command -v xray &> /dev/null; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

log "✓ Xray installed"

echo ""
log "=== Generating Reality Keys ==="

# Generate keys and extract properly
KEYS_OUTPUT=$(/usr/local/bin/xray x25519 2>&1)
echo "$KEYS_OUTPUT"

PRIVATE_KEY=$(echo "$KEYS_OUTPUT" | grep -i "private key:" | sed 's/.*: //' | tr -d ' \n\r')
PUBLIC_KEY=$(echo "$KEYS_OUTPUT" | grep -i "public key:" | sed 's/.*: //' | tr -d ' \n\r')

# Validate keys
if [ -z "$PRIVATE_KEY" ] || [ ${#PRIVATE_KEY} -lt 32 ]; then
    error "Failed to generate private key. Got: '$PRIVATE_KEY'"
fi

if [ -z "$PUBLIC_KEY" ] || [ ${#PUBLIC_KEY} -lt 32 ]; then
    error "Failed to generate public key. Got: '$PUBLIC_KEY'"
fi

SHORT_ID=$(openssl rand -hex 8)

echo ""
info "Keys generated successfully:"
info "  Private: ${PRIVATE_KEY:0:20}..."
info "  Public:  ${PUBLIC_KEY:0:20}..."
info "  ShortID: $SHORT_ID"

echo ""
log "=== Creating Xray Config ==="

mkdir -p /usr/local/etc/xray /var/log/xray

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.microsoft.com:443",
          "xver": 0,
          "serverNames": ["www.microsoft.com"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": 1080
          }
        ]
      }
    }
  ]
}
EOF

log "✓ Config created"

echo ""
log "=== Testing Config ==="
if ! /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json 2>&1 | head -20; then
    error "Config test failed. Check /usr/local/etc/xray/config.json"
fi

log "✓ Config valid"

echo ""
log "=== Starting Xray ==="
systemctl enable xray
systemctl restart xray
sleep 3

if systemctl is-active --quiet xray; then
    log "✓ Xray running"
else
    error "Xray failed. Check: journalctl -u xray -n 30"
fi

echo ""
log "=== Firewall ==="
if command -v ufw &> /dev/null; then
    ufw allow $PORT/tcp 2>/dev/null || true
    log "✓ UFW configured"
fi

echo ""
log "=== Enabling BBR ==="
if ! grep -q "bbr" /etc/sysctl.conf 2>/dev/null; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
fi
log "✓ BBR enabled"

echo ""
log "=== Verification ==="
systemctl is-active --quiet dnstt-server && log "✓ dnstt-server" || log "✗ dnstt-server"
systemctl is-active --quiet danted && log "✓ SOCKS5" || log "✗ SOCKS5"
systemctl is-active --quiet xray && log "✓ Xray" || log "✗ Xray"
ss -tuln | grep -q ":$PORT " && log "✓ Port $PORT" || log "✗ Port $PORT"

# Generate link
ENCODED_NAME=$(echo -n "$PROXY_NAME" | sed 's/ /%20/g')
CLIENT_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#${ENCODED_NAME}"

echo ""
log "=== Saving Config ==="
mkdir -p /root/proxy-config
cat > /root/proxy-config/info.txt <<ENDCONFIG
==============================================
DNSTT + VLESS-Reality Configuration
==============================================
Date: $(date)

Server: $SERVER_IP
Port: $PORT
UUID: $UUID
Public Key: $PUBLIC_KEY
Short ID: $SHORT_ID

Connection Link:
$CLIENT_LINK

Commands:
  Status:  systemctl status xray dnstt-server danted
  Logs:    journalctl -u xray -f
  Restart: systemctl restart xray dnstt-server danted

==============================================
ENDCONFIG

echo ""
echo -e "${GREEN}╔═════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     🎉 Setup Complete! 🎉                  ║${NC}"
echo -e "${GREEN}╚═════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Server:${NC} $SERVER_IP:$PORT"
echo ""
echo -e "${YELLOW}Connection Link:${NC}"
echo "$CLIENT_LINK"
echo ""
echo "Saved to: /root/proxy-config/info.txt"
echo ""
echo -e "${GREEN}Share this link with users!${NC}"
echo ""
