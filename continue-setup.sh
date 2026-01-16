#!/bin/bash

################################################################################
# DNSTT + V2Ray/Xray Setup - Continuation Script
# Use this when dnstt is already installed but needs reconfiguration
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
║  DNSTT + V2Ray/Xray Completion Script                 ║
║  Continue where automated script left off              ║
╚═════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# Check if running as root
[[ $EUID -ne 0 ]] && error "Run as root"

# Check if dnstt is installed
if ! systemctl is-active --quiet dnstt-server; then
    error "dnstt-server not running. Please install dnstt first."
fi

log "dnstt is running ✓"

# Get current configuration
if [ -f /etc/dnstt/dnstt-server.conf ]; then
    source /etc/dnstt/dnstt-server.conf
    log "Found existing dnstt config: $NAMESERVER_SUBDOMAIN"
fi

echo ""
info "=== Step 1: Reconfigure dnstt for SOCKS5 Mode ==="
echo ""
info "Current mode: SSH mode"
info "We need to change to SOCKS5 mode for V2Ray to work"
echo ""
read -p "Reconfigure dnstt now? (y/n): " RECONFIG

if [[ "$RECONFIG" == "y" || "$RECONFIG" == "Y" ]]; then
    log "Stopping dnstt-server..."
    systemctl stop dnstt-server
    
    # Check if dante is installed
    if ! command -v danted &> /dev/null; then
        log "Installing Dante SOCKS5 server..."
        apt-get update -qq
        apt-get install -y dante-server
    fi
    
    # Configure Dante
    log "Configuring Dante SOCKS5..."
    cat > /etc/danted.conf << 'EOF'
logoutput: syslog
internal: 127.0.0.1 port = 1080
external: eth0
clientmethod: none
socksmethod: none
user.privileged: root
user.unprivileged: nobody

client pass {
    from: 127.0.0.0/8 to: 0.0.0.0/0
    log: error
}

socks pass {
    from: 127.0.0.0/8 to: 0.0.0.0/0
    log: error
}
EOF
    
    # Update dnstt config
    sed -i 's/TUNNEL_MODE=.*/TUNNEL_MODE="socks"/' /etc/dnstt/dnstt-server.conf
    
    # Update systemd service
    sed -i 's|127.0.0.1:22|127.0.0.1:1080|g' /etc/systemd/system/dnstt-server.service
    
    systemctl daemon-reload
    
    # Start services
    systemctl enable danted
    systemctl start danted
    systemctl start dnstt-server
    
    if systemctl is-active --quiet danted; then
        log "✓ Dante SOCKS5 running on port 1080"
    else
        error "Failed to start Dante"
    fi
    
    if systemctl is-active --quiet dnstt-server; then
        log "✓ dnstt-server running"
    else
        error "Failed to start dnstt-server"
    fi
else
    log "Skipping dnstt reconfiguration"
fi

echo ""
info "=== Step 2: Configure V2Ray/Xray ==="
echo ""
info "Select protocol:"
echo "1) V2Ray (VMess)"
echo "2) Xray (VLESS-Reality) - Recommended"
read -p "Enter choice [1-2] (default: 2): " PROTOCOL_CHOICE
PROTOCOL_CHOICE=${PROTOCOL_CHOICE:-2}

# Get server IP
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
info "Server IP: $SERVER_IP"

# Generate UUID
UUID=$(cat /proc/sys/kernel/random/uuid)
info "Generated UUID: $UUID"

# Port
read -p "Enter port (default: 443): " PORT
PORT=${PORT:-443}

# Proxy name
read -p "Enter proxy name (default: MyProxy): " PROXY_NAME
PROXY_NAME=${PROXY_NAME:-MyProxy}

case $PROTOCOL_CHOICE in
    1)
        log "=== Installing V2Ray ==="
        bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)
        
        mkdir -p /usr/local/etc/v2ray /var/log/v2ray
        
        log "Creating V2Ray config..."
        cat > /usr/local/etc/v2ray/config.json << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "tcp"
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
        
        systemctl enable v2ray
        systemctl restart v2ray
        
        sleep 2
        if systemctl is-active --quiet v2ray; then
            log "✓ V2Ray running on port $PORT"
        else
            error "V2Ray failed to start. Check: journalctl -u v2ray -n 20"
        fi
        
        # Generate link
        JSON="{\"v\":\"2\",\"ps\":\"${PROXY_NAME}\",\"add\":\"${SERVER_IP}\",\"port\":\"${PORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"net\":\"tcp\",\"type\":\"none\",\"tls\":\"\"}"
        CLIENT_LINK="vmess://$(echo -n "$JSON" | base64 -w 0)"
        PROTOCOL_NAME="VMess"
        ;;
        
    2)
        log "=== Installing Xray ==="
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
        
        mkdir -p /usr/local/etc/xray
        
        # Generate keys
        log "Generating Reality keys..."
        KEYS=$(/usr/local/bin/xray x25519)
        PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | awk '{print $3}')
        PUBLIC_KEY=$(echo "$KEYS" | grep "Public key:" | awk '{print $3}')
        SHORT_ID=$(openssl rand -hex 8)
        
        log "Creating Xray config..."
        cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
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
          "serverNames": [
            "www.microsoft.com"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
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
        
        systemctl enable xray
        systemctl restart xray
        
        sleep 2
        if systemctl is-active --quiet xray; then
            log "✓ Xray running on port $PORT"
        else
            error "Xray failed to start. Check: journalctl -u xray -n 20"
        fi
        
        # Generate link
        CLIENT_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#${PROXY_NAME// /%20}"
        PROTOCOL_NAME="VLESS-Reality"
        ;;
esac

echo ""
log "=== Configuring Firewall ==="
if command -v ufw &> /dev/null; then
    ufw allow 22/tcp
    ufw allow 53/udp
    ufw allow ${PORT}/tcp
    ufw --force enable
    log "✓ UFW configured"
fi

echo ""
log "=== Enabling BBR ==="
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null
    log "✓ BBR enabled"
fi

echo ""
log "=== Saving Configuration ==="
mkdir -p /root/dnstt-v2ray-config

cat > /root/dnstt-v2ray-config/info.txt << EOF
=======================================================
  Configuration
=======================================================

Protocol: ${PROTOCOL_NAME}
Server: ${SERVER_IP}
Port: ${PORT}
UUID: ${UUID}
$([ "$PROTOCOL_CHOICE" == "2" ] && echo "Public Key: ${PUBLIC_KEY}")
$([ "$PROTOCOL_CHOICE" == "2" ] && echo "Short ID: ${SHORT_ID}")

Connection Link:
${CLIENT_LINK}

Management:
- Check status: systemctl status xray dnstt-server danted
- View logs: journalctl -u xray -f
- Restart: systemctl restart xray dnstt-server danted

=======================================================
EOF

echo ""
echo -e "${GREEN}╔═════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          🎉 Installation Complete! 🎉                  ║${NC}"
echo -e "${GREEN}╚═════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Protocol:${NC} $PROTOCOL_NAME"
echo -e "${BLUE}Server:${NC} $SERVER_IP:$PORT"
echo ""
echo -e "${YELLOW}Connection Link:${NC}"
echo "$CLIENT_LINK"
echo ""
echo "Configuration saved: /root/dnstt-v2ray-config/info.txt"
echo ""
echo -e "${GREEN}✓ Share the link above with users!${NC}"
echo ""
