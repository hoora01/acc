#!/bin/bash

################################################################################
# DNSTT + V2Ray/Xray Automated Integration Script
# 
# This script automatically sets up:
# - dnstt DNS tunnel server with SOCKS5 proxy
# - V2Ray or Xray server configured to route through dnstt
# - Generates client configuration and subscription links
# - Complete firewall and security setup
#
# Requirements:
# - Fresh Ubuntu/Debian/CentOS/Rocky Linux VPS
# - Root or sudo access
# - Domain name with DNS configured
#
# Usage:
#   bash <(curl -Ls https://raw.githubusercontent.com/YOUR_REPO/setup.sh)
#   or
#   wget https://raw.githubusercontent.com/YOUR_REPO/setup.sh && bash setup.sh
#
################################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log file
LOG_FILE="/var/log/dnstt-v2ray-setup.log"

################################################################################
# Helper Functions
################################################################################

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

print_banner() {
    echo -e "${GREEN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║     DNSTT + V2Ray/Xray Automated Setup Script           ║
║     DNS Tunnel with V2Ray Protocol Integration           ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root or with sudo"
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        error "Cannot detect OS. /etc/os-release not found."
    fi
    
    log "Detected OS: $OS $VER"
}

check_dependencies() {
    log "Checking for required commands..."
    
    local deps=("curl" "wget" "systemctl")
    for dep in "${deps[@]}"; do
        if ! command -v $dep &> /dev/null; then
            warn "$dep not found, installing..."
            case $OS in
                ubuntu|debian)
                    apt-get update -qq
                    apt-get install -y $dep
                    ;;
                centos|rhel|rocky|fedora)
                    yum install -y $dep
                    ;;
            esac
        fi
    done
}

generate_uuid() {
    if command -v uuidgen &> /dev/null; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

generate_password() {
    openssl rand -base64 16 | tr -d "=+/" | cut -c1-16
}

################################################################################
# User Input Collection
################################################################################

collect_user_input() {
    echo ""
    log "=== Configuration Setup ==="
    echo ""
    
    # Protocol selection
    info "Select proxy protocol:"
    echo "1) V2Ray (VMess)"
    echo "2) Xray (VLESS-Reality) - Recommended"
    echo "3) Xray (Trojan)"
    read -p "Enter choice [1-3] (default: 2): " PROTOCOL_CHOICE
    PROTOCOL_CHOICE=${PROTOCOL_CHOICE:-2}
    
    case $PROTOCOL_CHOICE in
        1) PROTOCOL="v2ray"; PROTOCOL_NAME="VMess" ;;
        2) PROTOCOL="xray"; PROTOCOL_NAME="VLESS-Reality" ;;
        3) PROTOCOL="xray-trojan"; PROTOCOL_NAME="Trojan" ;;
        *) PROTOCOL="xray"; PROTOCOL_NAME="VLESS-Reality" ;;
    esac
    
    log "Selected protocol: $PROTOCOL_NAME"
    
    # Domain configuration
    echo ""
    info "Domain Configuration:"
    read -p "Enter your DNS tunnel subdomain (e.g., t.example.com): " DNS_DOMAIN
    
    while [[ -z "$DNS_DOMAIN" ]]; do
        warn "DNS domain cannot be empty!"
        read -p "Enter your DNS tunnel subdomain (e.g., t.example.com): " DNS_DOMAIN
    done
    
    # Get server IP
    SERVER_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || curl -s ipinfo.io/ip)
    info "Detected server IP: $SERVER_IP"
    read -p "Confirm server IP or enter manually [$SERVER_IP]: " USER_IP
    SERVER_IP=${USER_IP:-$SERVER_IP}
    
    # V2Ray domain (optional for some protocols)
    if [[ "$PROTOCOL_CHOICE" == "1" ]] || [[ "$PROTOCOL_CHOICE" == "3" ]]; then
        echo ""
        read -p "Enter domain for $PROTOCOL_NAME (press Enter to use IP): " V2RAY_DOMAIN
        V2RAY_DOMAIN=${V2RAY_DOMAIN:-$SERVER_IP}
        
        if [[ "$V2RAY_DOMAIN" != "$SERVER_IP" ]]; then
            USE_TLS="yes"
            info "Will setup SSL certificate for $V2RAY_DOMAIN"
        else
            USE_TLS="no"
            info "Using IP address, TLS will be disabled"
        fi
    else
        V2RAY_DOMAIN=$SERVER_IP
        USE_TLS="no"
    fi
    
    # Port configuration
    echo ""
    read -p "Enter V2Ray/Xray port (default: 443): " V2RAY_PORT
    V2RAY_PORT=${V2RAY_PORT:-443}
    
    # MTU configuration
    read -p "Enter MTU value for dnstt (default: 1232): " DNS_MTU
    DNS_MTU=${DNS_MTU:-1232}
    
    # Generate credentials
    UUID=$(generate_uuid)
    PASSWORD=$(generate_password)
    
    # User configuration
    echo ""
    read -p "Enter a name for this proxy (default: MyDNSTunnel): " PROXY_NAME
    PROXY_NAME=${PROXY_NAME:-MyDNSTunnel}
    
    # Confirm settings
    echo ""
    log "=== Configuration Summary ==="
    echo "Protocol: $PROTOCOL_NAME"
    echo "DNS Domain: $DNS_DOMAIN"
    echo "Server IP: $SERVER_IP"
    echo "V2Ray Domain: $V2RAY_DOMAIN"
    echo "V2Ray Port: $V2RAY_PORT"
    echo "DNS MTU: $DNS_MTU"
    echo "UUID: $UUID"
    if [[ "$PROTOCOL_CHOICE" == "3" ]]; then
        echo "Password: $PASSWORD"
    fi
    echo ""
    
    read -p "Continue with these settings? (y/n): " CONFIRM
    if [[ "$CONFIRM" != "y" ]] && [[ "$CONFIRM" != "Y" ]]; then
        error "Installation cancelled by user"
    fi
}

################################################################################
# Installation Functions
################################################################################

install_dnstt() {
    log "=== Installing dnstt DNS Tunnel ==="
    
    # Create temporary expect script for automation
    cat > /tmp/dnstt-setup.exp << EOF
#!/usr/bin/expect -f
set timeout 300

spawn bash -c "curl -Ls https://raw.githubusercontent.com/bugfloyd/dnstt-deploy/main/dnstt-deploy.sh | bash"

expect "Enter the nameserver subdomain*"
send "${DNS_DOMAIN}\r"

expect "Enter the MTU*"
send "${DNS_MTU}\r"

expect "Select tunnel mode*"
send "1\r"

expect eof
EOF
    
    chmod +x /tmp/dnstt-setup.exp
    
    # Install expect if not available
    if ! command -v expect &> /dev/null; then
        log "Installing expect..."
        case $OS in
            ubuntu|debian)
                apt-get install -y expect
                ;;
            centos|rhel|rocky|fedora)
                yum install -y expect
                ;;
        esac
    fi
    
    # Run automated installation
    /tmp/dnstt-setup.exp || {
        warn "Automated dnstt installation may have issues. Checking services..."
    }
    
    rm -f /tmp/dnstt-setup.exp
    
    # Verify installation
    sleep 5
    if systemctl is-active --quiet dnstt-server && systemctl is-active --quiet danted; then
        log "dnstt installed successfully"
    else
        error "dnstt installation failed. Check logs: sudo journalctl -u dnstt-server -u danted"
    fi
}

install_v2ray() {
    log "=== Installing V2Ray ==="
    
    bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh) || error "V2Ray installation failed"
    
    log "V2Ray installed successfully"
}

install_xray() {
    log "=== Installing Xray ==="
    
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install || error "Xray installation failed"
    
    log "Xray installed successfully"
}

configure_v2ray_vmess() {
    log "=== Configuring V2Ray (VMess) ==="
    
    local config_file="/usr/local/etc/v2ray/config.json"
    
    if [[ "$USE_TLS" == "yes" ]]; then
        # VMess with TLS
        cat > "$config_file" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/v2ray/access.log",
    "error": "/var/log/v2ray/error.log"
  },
  "inbounds": [
    {
      "port": ${V2RAY_PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "alterId": 0,
            "email": "user@${V2RAY_DOMAIN}"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/vmess"
        },
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "/etc/letsencrypt/live/${V2RAY_DOMAIN}/fullchain.pem",
              "keyFile": "/etc/letsencrypt/live/${V2RAY_DOMAIN}/privkey.pem"
            }
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
      },
      "tag": "dns-tunnel"
    },
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "outboundTag": "dns-tunnel",
        "network": "tcp,udp"
      }
    ]
  }
}
EOF
    else
        # VMess without TLS
        cat > "$config_file" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/v2ray/access.log",
    "error": "/var/log/v2ray/error.log"
  },
  "inbounds": [
    {
      "port": ${V2RAY_PORT},
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
        "network": "tcp",
        "security": "none"
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
      },
      "tag": "dns-tunnel"
    },
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "outboundTag": "dns-tunnel",
        "network": "tcp,udp"
      }
    ]
  }
}
EOF
    fi
    
    # Create log directory
    mkdir -p /var/log/v2ray
    
    log "V2Ray configuration created"
}

configure_xray_reality() {
    log "=== Configuring Xray (VLESS-Reality) ==="
    
    local config_file="/usr/local/etc/xray/config.json"
    
    # Generate Reality keys
    local keys_output=$(/usr/local/bin/xray x25519)
    PRIVATE_KEY=$(echo "$keys_output" | grep "Private key:" | awk '{print $3}')
    PUBLIC_KEY=$(echo "$keys_output" | grep "Public key:" | awk '{print $3}')
    SHORT_ID=$(openssl rand -hex 8)
    
    cat > "$config_file" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": ${V2RAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "email": "user@reality"
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
            "www.microsoft.com",
            "www.bing.com"
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
      },
      "tag": "dns-tunnel"
    },
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "outboundTag": "dns-tunnel",
        "network": "tcp,udp"
      }
    ]
  }
}
EOF
    
    # Create log directory
    mkdir -p /var/log/xray
    
    log "Xray Reality configuration created"
    log "Public Key: $PUBLIC_KEY"
    log "Short ID: $SHORT_ID"
}

configure_xray_trojan() {
    log "=== Configuring Xray (Trojan) ==="
    
    local config_file="/usr/local/etc/xray/config.json"
    
    if [[ "$USE_TLS" == "yes" ]]; then
        cat > "$config_file" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": ${V2RAY_PORT},
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password": "${PASSWORD}",
            "email": "user@${V2RAY_DOMAIN}"
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "/etc/letsencrypt/live/${V2RAY_DOMAIN}/fullchain.pem",
              "keyFile": "/etc/letsencrypt/live/${V2RAY_DOMAIN}/privkey.pem"
            }
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
      },
      "tag": "dns-tunnel"
    },
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "outboundTag": "dns-tunnel",
        "network": "tcp,udp"
      }
    ]
  }
}
EOF
    else
        error "Trojan protocol requires TLS. Please use a domain name."
    fi
    
    mkdir -p /var/log/xray
    
    log "Xray Trojan configuration created"
}

install_ssl_certificate() {
    if [[ "$USE_TLS" != "yes" ]]; then
        return
    fi
    
    log "=== Installing SSL Certificate ==="
    
    # Install certbot
    case $OS in
        ubuntu|debian)
            apt-get update
            apt-get install -y certbot
            ;;
        centos|rhel|rocky|fedora)
            yum install -y certbot
            ;;
    esac
    
    # Stop services temporarily to use port 80
    systemctl stop v2ray 2>/dev/null || true
    systemctl stop xray 2>/dev/null || true
    
    # Get certificate
    certbot certonly --standalone --non-interactive --agree-tos \
        --email admin@${V2RAY_DOMAIN} \
        -d ${V2RAY_DOMAIN} || {
        warn "SSL certificate installation failed. You can manually install it later."
        USE_TLS="no"
        return
    }
    
    log "SSL certificate installed successfully"
    
    # Setup auto-renewal
    systemctl enable certbot.timer 2>/dev/null || true
}

configure_firewall() {
    log "=== Configuring Firewall ==="
    
    if command -v ufw &> /dev/null; then
        # UFW (Ubuntu/Debian)
        ufw --force enable
        ufw allow 22/tcp comment 'SSH'
        ufw allow 53/udp comment 'DNS Tunnel'
        ufw allow ${V2RAY_PORT}/tcp comment 'V2Ray/Xray'
        ufw allow 80/tcp comment 'HTTP (for SSL renewal)'
        ufw reload
        log "UFW firewall configured"
    elif command -v firewall-cmd &> /dev/null; then
        # FirewallD (CentOS/Rocky/Fedora)
        systemctl start firewalld
        systemctl enable firewalld
        firewall-cmd --permanent --add-port=22/tcp
        firewall-cmd --permanent --add-port=53/udp
        firewall-cmd --permanent --add-port=${V2RAY_PORT}/tcp
        firewall-cmd --permanent --add-port=80/tcp
        firewall-cmd --reload
        log "FirewallD configured"
    else
        # Basic iptables
        iptables -I INPUT -p tcp --dport 22 -j ACCEPT
        iptables -I INPUT -p udp --dport 53 -j ACCEPT
        iptables -I INPUT -p tcp --dport ${V2RAY_PORT} -j ACCEPT
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT
        
        # Save iptables rules
        case $OS in
            ubuntu|debian)
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                ;;
            centos|rhel|rocky|fedora)
                iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
                ;;
        esac
        
        log "Basic iptables rules configured"
    fi
}

enable_bbr() {
    log "=== Enabling BBR TCP Congestion Control ==="
    
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        log "BBR enabled"
    else
        log "BBR already enabled"
    fi
}

start_services() {
    log "=== Starting Services ==="
    
    # Start and enable dnstt services
    systemctl restart dnstt-server
    systemctl restart danted
    systemctl enable dnstt-server
    systemctl enable danted
    
    # Start and enable v2ray/xray
    case $PROTOCOL in
        v2ray)
            systemctl restart v2ray
            systemctl enable v2ray
            sleep 2
            if systemctl is-active --quiet v2ray; then
                log "V2Ray service started successfully"
            else
                error "V2Ray service failed to start. Check: journalctl -u v2ray -n 50"
            fi
            ;;
        xray|xray-trojan)
            systemctl restart xray
            systemctl enable xray
            sleep 2
            if systemctl is-active --quiet xray; then
                log "Xray service started successfully"
            else
                error "Xray service failed to start. Check: journalctl -u xray -n 50"
            fi
            ;;
    esac
    
    log "All services started and enabled"
}

verify_installation() {
    log "=== Verifying Installation ==="
    
    local errors=0
    
    # Check dnstt
    if systemctl is-active --quiet dnstt-server; then
        log "✓ dnstt-server is running"
    else
        warn "✗ dnstt-server is not running"
        ((errors++))
    fi
    
    # Check SOCKS5
    if systemctl is-active --quiet danted; then
        log "✓ SOCKS5 proxy is running"
    else
        warn "✗ SOCKS5 proxy is not running"
        ((errors++))
    fi
    
    # Check V2Ray/Xray
    case $PROTOCOL in
        v2ray)
            if systemctl is-active --quiet v2ray; then
                log "✓ V2Ray is running"
            else
                warn "✗ V2Ray is not running"
                ((errors++))
            fi
            ;;
        xray|xray-trojan)
            if systemctl is-active --quiet xray; then
                log "✓ Xray is running"
            else
                warn "✗ Xray is not running"
                ((errors++))
            fi
            ;;
    esac
    
    # Check ports
    if ss -tuln | grep -q ":53 "; then
        log "✓ Port 53 is listening (DNS)"
    else
        warn "✗ Port 53 is not listening"
        ((errors++))
    fi
    
    if ss -tuln | grep -q ":${V2RAY_PORT} "; then
        log "✓ Port ${V2RAY_PORT} is listening (V2Ray/Xray)"
    else
        warn "✗ Port ${V2RAY_PORT} is not listening"
        ((errors++))
    fi
    
    if ss -tuln | grep -q ":1080 "; then
        log "✓ Port 1080 is listening (SOCKS5)"
    else
        warn "✗ Port 1080 is not listening"
        ((errors++))
    fi
    
    if [ $errors -eq 0 ]; then
        log "All checks passed! ✓"
    else
        warn "Some checks failed. Please review the logs."
    fi
}

################################################################################
# Client Configuration Generation
################################################################################

generate_vmess_link() {
    local vmess_json=$(cat <<EOF
{
  "v": "2",
  "ps": "${PROXY_NAME}",
  "add": "${SERVER_IP}",
  "port": "${V2RAY_PORT}",
  "id": "${UUID}",
  "aid": "0",
  "net": "$([ "$USE_TLS" == "yes" ] && echo "ws" || echo "tcp")",
  "type": "none",
  "host": "${V2RAY_DOMAIN}",
  "path": "$([ "$USE_TLS" == "yes" ] && echo "/vmess" || echo "")",
  "tls": "$([ "$USE_TLS" == "yes" ] && echo "tls" || echo "")"
}
EOF
)
    
    echo "vmess://$(echo -n "$vmess_json" | base64 -w 0)"
}

generate_vless_link() {
    local vless_link="vless://${UUID}@${SERVER_IP}:${V2RAY_PORT}?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#${PROXY_NAME// /%20}"
    echo "$vless_link"
}

generate_trojan_link() {
    local trojan_link="trojan://${PASSWORD}@${V2RAY_DOMAIN}:${V2RAY_PORT}?security=tls&sni=${V2RAY_DOMAIN}&type=tcp#${PROXY_NAME// /%20}"
    echo "$trojan_link"
}

generate_qr_code() {
    local link="$1"
    local output_file="$2"
    
    if command -v qrencode &> /dev/null; then
        qrencode -t ANSIUTF8 "$link"
        qrencode -t PNG -o "$output_file" "$link" 2>/dev/null || true
    else
        info "Install qrencode to generate QR codes: apt install qrencode"
    fi
}

save_configuration() {
    local config_dir="/root/dnstt-v2ray-config"
    mkdir -p "$config_dir"
    
    local config_file="$config_dir/config.txt"
    local info_file="$config_dir/client-info.txt"
    
    # Save server configuration
    cat > "$config_file" << EOF
=======================================================
  DNSTT + V2Ray/Xray Server Configuration
=======================================================

Installation Date: $(date)
Protocol: ${PROTOCOL_NAME}

=== Server Information ===
Server IP: ${SERVER_IP}
DNS Domain: ${DNS_DOMAIN}
V2Ray Domain: ${V2RAY_DOMAIN}
V2Ray Port: ${V2RAY_PORT}
DNS MTU: ${DNS_MTU}

=== Credentials ===
UUID: ${UUID}
$([ "$PROTOCOL_CHOICE" == "3" ] && echo "Password: ${PASSWORD}")
$([ "$PROTOCOL_CHOICE" == "2" ] && echo "Public Key: ${PUBLIC_KEY}")
$([ "$PROTOCOL_CHOICE" == "2" ] && echo "Short ID: ${SHORT_ID}")

=== Service Status ===
dnstt-server: $(systemctl is-active dnstt-server)
danted (SOCKS5): $(systemctl is-active danted)
$([ "$PROTOCOL" == "v2ray" ] && echo "v2ray: $(systemctl is-active v2ray)")
$([ "$PROTOCOL" != "v2ray" ] && echo "xray: $(systemctl is-active xray)")

=== Management Commands ===
Check status: dnstt-deploy (menu option 3)
View logs: journalctl -u $([ "$PROTOCOL" == "v2ray" ] && echo "v2ray" || echo "xray") -f
Restart services:
  systemctl restart dnstt-server
  systemctl restart danted
  systemctl restart $([ "$PROTOCOL" == "v2ray" ] && echo "v2ray" || echo "xray")

=======================================================
EOF
    
    # Generate client link
    case $PROTOCOL_CHOICE in
        1)
            CLIENT_LINK=$(generate_vmess_link)
            ;;
        2)
            CLIENT_LINK=$(generate_vless_link)
            ;;
        3)
            CLIENT_LINK=$(generate_trojan_link)
            ;;
    esac
    
    # Save client information
    cat > "$info_file" << EOF
=======================================================
  Client Configuration - Share with Users
=======================================================

Proxy Name: ${PROXY_NAME}
Protocol: ${PROTOCOL_NAME}

=== Connection Link ===
${CLIENT_LINK}

=== Manual Configuration (if needed) ===
Server: ${SERVER_IP}
Port: ${V2RAY_PORT}
UUID: ${UUID}
$([ "$PROTOCOL_CHOICE" == "3" ] && echo "Password: ${PASSWORD}")
$([ "$PROTOCOL_CHOICE" == "2" ] && echo "Public Key: ${PUBLIC_KEY}")
$([ "$PROTOCOL_CHOICE" == "2" ] && echo "Short ID: ${SHORT_ID}")
$([ "$USE_TLS" == "yes" ] && echo "TLS: Enabled")
$([ "$USE_TLS" == "yes" ] && echo "SNI: ${V2RAY_DOMAIN}")

=== Supported Clients ===
Android: V2RayNG, SagerNet, Shadowsocket
iOS: Shadowrocket, Quantumult X, Streisand
Windows: V2RayN, Clash for Windows, NekoRay
macOS: V2RayX, V2RayU, ClashX
Linux: Qv2ray, V2Ray CLI

=== How to Use ===
1. Install a V2Ray/Xray compatible client
2. Copy the connection link above
3. Import into your client:
   - Android/iOS: Scan QR code or paste link
   - Windows/Mac: Import from clipboard
4. Connect and enjoy!

=== For Telegram ===
After connecting V2Ray client:
1. Open Telegram
2. Settings → Data and Storage → Proxy Settings
3. Add Proxy → SOCKS5
4. Server: 127.0.0.1
5. Port: 1080 (or your V2Ray local port)

=======================================================
EOF
    
    # Try to generate QR code
    generate_qr_code "$CLIENT_LINK" "$config_dir/qrcode.png"
    
    log "Configuration saved to: $config_dir"
}

################################################################################
# Display Results
################################################################################

display_results() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                           ║${NC}"
    echo -e "${GREEN}║          🎉 Installation Completed Successfully! 🎉       ║${NC}"
    echo -e "${GREEN}║                                                           ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    echo -e "${BLUE}=== Server Information ===${NC}"
    echo "Protocol: $PROTOCOL_NAME"
    echo "Server IP: $SERVER_IP"
    echo "Port: $V2RAY_PORT"
    echo ""
    
    echo -e "${BLUE}=== Client Connection Link ===${NC}"
    echo -e "${YELLOW}$CLIENT_LINK${NC}"
    echo ""
    
    echo -e "${BLUE}=== QR Code ===${NC}"
    generate_qr_code "$CLIENT_LINK" "/tmp/qr.png"
    echo ""
    
    echo -e "${BLUE}=== Configuration Files ===${NC}"
    echo "Server config: /root/dnstt-v2ray-config/config.txt"
    echo "Client info: /root/dnstt-v2ray-config/client-info.txt"
    echo "QR Code: /root/dnstt-v2ray-config/qrcode.png (if available)"
    echo ""
    
    echo -e "${BLUE}=== Management Commands ===${NC}"
    echo "View status: systemctl status $([ "$PROTOCOL" == "v2ray" ] && echo "v2ray" || echo "xray")"
    echo "View logs: journalctl -u $([ "$PROTOCOL" == "v2ray" ] && echo "v2ray" || echo "xray") -f"
    echo "Restart: systemctl restart $([ "$PROTOCOL" == "v2ray" ] && echo "v2ray" || echo "xray")"
    echo "dnstt menu: dnstt-deploy"
    echo ""
    
    echo -e "${BLUE}=== Next Steps ===${NC}"
    echo "1. Share the connection link with users"
    echo "2. Users install V2Ray/Xray client app"
    echo "3. Users import the link"
    echo "4. Users can then use it with Telegram or any app"
    echo ""
    
    echo -e "${GREEN}✓ Setup complete! Enjoy your DNS tunnel + V2Ray/Xray proxy!${NC}"
    echo ""
    
    read -p "Press Enter to view detailed configuration..."
    cat /root/dnstt-v2ray-config/client-info.txt
}

################################################################################
# Cleanup and Error Handling
################################################################################

cleanup() {
    log "Cleaning up temporary files..."
    rm -f /tmp/dnstt-setup.exp
}

trap cleanup EXIT

################################################################################
# Main Installation Flow
################################################################################

main() {
    print_banner
    
    log "Starting DNSTT + V2Ray/Xray automated installation..."
    
    # Pre-installation checks
    check_root
    detect_os
    check_dependencies
    
    # User configuration
    collect_user_input
    
    # Installation steps
    install_dnstt
    
    case $PROTOCOL in
        v2ray)
            install_v2ray
            install_ssl_certificate
            configure_v2ray_vmess
            ;;
        xray)
            install_xray
            configure_xray_reality
            ;;
        xray-trojan)
            install_xray
            install_ssl_certificate
            configure_xray_trojan
            ;;
    esac
    
    # Configuration and optimization
    configure_firewall
    enable_bbr
    
    # Start services
    start_services
    
    # Verification
    verify_installation
    
    # Save configuration
    save_configuration
    
    # Display results
    display_results
    
    log "Installation completed at $(date)"
}

# Run main function
main "$@"
