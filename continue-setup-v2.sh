#!/bin/bash

################################################################################
# DNSTT + V2Ray/Xray Setup - Continuation Script v2
# Fixed: Proper config file creation and error handling
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
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

echo -e "${GREEN}"
cat << "EOF"
╔═════════════════════════════════════════════════════════╗
║  DNSTT + V2Ray/Xray Completion Script v2               ║
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

# Check if already configured for SOCKS5
if systemctl is-active --quiet danted 2>/dev/null && grep -q "127.0.0.1:1080" /etc/systemd/system/dnstt-server.service 2>/dev/null; then
    log "✓ Already configured for SOCKS5 mode"
else
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
        cat > /etc/danted.conf << 'DANTEEOF'
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
DANTEEOF
        
        # Update dnstt config if file exists
        if [ -f /etc/dnstt/dnstt-server.conf ]; then
            sed -i 's/TUNNEL_MODE=.*/TUNNEL_MODE="socks"/' /etc/dnstt/dnstt-server.conf
        fi
        
        # Update systemd service
        sed -i 's|127.0.0.1:22|127.0.0.1:1080|g' /etc/systemd/system/dnstt-server.service
        
        systemctl daemon-reload
        
        # Start services
        systemctl enable danted
        systemctl start danted
        systemctl start dnstt-server
        
        sleep 2
        
        if systemctl is-active --quiet danted; then
            log "✓ Dante SOCKS5 running on port 1080"
        else
            error "Failed to start Dante. Check: journalctl -u danted -n 20"
        fi
        
        if systemctl is-active --quiet dnstt-server; then
            log "✓ dnstt-server running"
        else
            error "Failed to start dnstt-server. Check: journalctl -u dnstt-server -n 20"
        fi
    else
        log "Skipping dnstt reconfiguration"
    fi
fi

# Test SOCKS5 connectivity
log "Testing SOCKS5 proxy..."
if timeout 5 curl -s -x socks5://127.0.0.1:1080 https://ipinfo.io > /dev/null 2>&1; then
    log "✓ SOCKS5 proxy working"
else
    warn "SOCKS5 proxy test failed, but continuing..."
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
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
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
        bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh) || error "V2Ray installation failed"
        
        mkdir -p /usr/local/etc/v2ray /var/log/v2ray
        
        log "Creating V2Ray config..."
        cat > /usr/local/etc/v2ray/config.json << VMESSEOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/v2ray/access.log",
    "error": "/var/log/v2ray/error.log"
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
VMESSEOF
        
        # Test config
        log "Testing V2Ray configuration..."
        if /usr/local/bin/v2ray test -config /usr/local/etc/v2ray/config.json; then
            log "✓ Config is valid"
        else
            error "V2Ray config is invalid"
        fi
        
        systemctl enable v2ray
        systemctl restart v2ray
        
        sleep 3
        if systemctl is-active --quiet v2ray; then
            log "✓ V2Ray running on port $PORT"
        else
            error "V2Ray failed to start. Check: journalctl -u v2ray -n 30"
        fi
        
        # Generate link
        JSON="{\"v\":\"2\",\"ps\":\"${PROXY_NAME}\",\"add\":\"${SERVER_IP}\",\"port\":\"${PORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"net\":\"tcp\",\"type\":\"none\",\"tls\":\"\"}"
        CLIENT_LINK="vmess://$(echo -n "$JSON" | base64 -w 0)"
        PROTOCOL_NAME="VMess"
        SERVICE_NAME="v2ray"
        ;;
        
    2)
        log "=== Installing Xray ==="
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install || error "Xray installation failed"
        
        mkdir -p /usr/local/etc/xray /var/log/xray
        
        # Generate keys
        log "Generating Reality keys..."
        KEYS=$(/usr/local/bin/xray x25519)
        PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | awk '{print $3}')
        PUBLIC_KEY=$(echo "$KEYS" | grep "Public key:" | awk '{print $3}')
        SHORT_ID=$(openssl rand -hex 8)
        
        info "Keys generated:"
        info "  Private Key: $PRIVATE_KEY"
        info "  Public Key: $PUBLIC_KEY"
        info "  Short ID: $SHORT_ID"
        
        log "Creating Xray config..."
        
        # Create config with proper escaping
        cat > /usr/local/etc/xray/config.json << XRAYEOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
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
XRAYEOF
        
        # Verify config file was created
        if [ ! -f /usr/local/etc/xray/config.json ]; then
            error "Failed to create Xray config file"
        fi
        
        log "Config file created: $(wc -l < /usr/local/etc/xray/config.json) lines"
        
        # Test config
        log "Testing Xray configuration..."
        if /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json; then
            log "✓ Config is valid"
        else
            error "Xray config is invalid. Check the file at /usr/local/etc/xray/config.json"
        fi
        
        systemctl enable xray
        systemctl restart xray
        
        sleep 3
        if systemctl is-active --quiet xray; then
            log "✓ Xray running on port $PORT"
        else
            error "Xray failed to start. Check: journalctl -u xray -n 30"
        fi
        
        # Generate link - properly URL encode the proxy name
        ENCODED_NAME=$(echo -n "$PROXY_NAME" | sed 's/ /%20/g')
        CLIENT_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#${ENCODED_NAME}"
        PROTOCOL_NAME="VLESS-Reality"
        SERVICE_NAME="xray"
        ;;
esac

echo ""
log "=== Configuring Firewall ==="
if command -v ufw &> /dev/null; then
    ufw allow 22/tcp comment 'SSH' 2>/dev/null || true
    ufw allow 53/udp comment 'DNS' 2>/dev/null || true
    ufw allow ${PORT}/tcp comment 'Proxy' 2>/dev/null || true
    ufw --force enable
    log "✓ UFW configured"
elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=22/tcp 2>/dev/null || true
    firewall-cmd --permanent --add-port=53/udp 2>/dev/null || true
    firewall-cmd --permanent --add-port=${PORT}/tcp 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    log "✓ FirewallD configured"
else
    warn "No firewall detected. Please manually allow ports: 22/tcp, 53/udp, ${PORT}/tcp"
fi

echo ""
log "=== Enabling BBR ==="
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1
    log "✓ BBR enabled"
else
    log "✓ BBR already enabled"
fi

echo ""
log "=== Final Verification ==="
sleep 2

# Check all services
ERRORS=0

if systemctl is-active --quiet dnstt-server; then
    log "✓ dnstt-server is running"
else
    warn "✗ dnstt-server is not running"
    ((ERRORS++))
fi

if systemctl is-active --quiet danted; then
    log "✓ SOCKS5 proxy is running"
else
    warn "✗ SOCKS5 proxy is not running"
    ((ERRORS++))
fi

if systemctl is-active --quiet $SERVICE_NAME; then
    log "✓ $PROTOCOL_NAME is running"
else
    warn "✗ $PROTOCOL_NAME is not running"
    ((ERRORS++))
fi

# Check ports
if ss -tuln | grep -q ":53 "; then
    log "✓ Port 53 listening"
else
    warn "✗ Port 53 not listening"
    ((ERRORS++))
fi

if ss -tuln | grep -q ":${PORT} "; then
    log "✓ Port ${PORT} listening"
else
    warn "✗ Port ${PORT} not listening"
    ((ERRORS++))
fi

if ss -tuln | grep -q ":1080 "; then
    log "✓ Port 1080 listening (SOCKS5)"
else
    warn "✗ Port 1080 not listening"
    ((ERRORS++))
fi

if [ $ERRORS -gt 0 ]; then
    warn "Some checks failed. Please review the logs."
else
    log "All checks passed! ✓"
fi

echo ""
log "=== Saving Configuration ==="
mkdir -p /root/dnstt-v2ray-config

cat > /root/dnstt-v2ray-config/info.txt << CONFIGEOF
=======================================================
  DNSTT + ${PROTOCOL_NAME} Configuration
=======================================================

Date: $(date)

Server Information:
  Protocol: ${PROTOCOL_NAME}
  Server IP: ${SERVER_IP}
  Port: ${PORT}
  UUID: ${UUID}
$([ "$PROTOCOL_CHOICE" == "2" ] && echo "  Public Key: ${PUBLIC_KEY}")
$([ "$PROTOCOL_CHOICE" == "2" ] && echo "  Short ID: ${SHORT_ID}")

Connection Link:
${CLIENT_LINK}

Service Status:
  dnstt-server: $(systemctl is-active dnstt-server)
  danted (SOCKS5): $(systemctl is-active danted)
  ${SERVICE_NAME}: $(systemctl is-active $SERVICE_NAME)

Management Commands:
  Check status:  systemctl status ${SERVICE_NAME} dnstt-server danted
  View logs:     journalctl -u ${SERVICE_NAME} -f
  Restart all:   systemctl restart ${SERVICE_NAME} dnstt-server danted
  
  View this config: cat /root/dnstt-v2ray-config/info.txt

Client Setup:
  1. Install V2Ray/Xray client app on your device
  2. Import the connection link above
  3. Connect
  4. For Telegram: Settings → Proxy → SOCKS5 → 127.0.0.1:1080

=======================================================
CONFIGEOF

log "Configuration saved to: /root/dnstt-v2ray-config/info.txt"

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
echo -e "${GREEN}Configuration saved to: /root/dnstt-v2ray-config/info.txt${NC}"
echo ""
echo -e "${BLUE}Next Steps:${NC}"
echo "1. Copy the connection link above"
echo "2. Share with users to import in their V2Ray/Xray client"
echo "3. Users can then connect and use Telegram through the proxy"
echo ""
echo -e "${GREEN}✓ Setup complete! Enjoy your DNS tunnel + ${PROTOCOL_NAME} proxy!${NC}"
echo ""
