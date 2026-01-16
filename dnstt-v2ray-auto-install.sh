#!/bin/bash

################################################################################
# DNSTT + V2Ray/Xray Automated Integration Script v2.0
# Fixed: Better handling of dnstt interactive installation
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
║     DNSTT + V2Ray/Xray Automated Setup Script v2.0      ║
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

install_dnstt_manual() {
    log "=== Installing dnstt DNS Tunnel (Manual Method) ==="
    
    # First, ensure we have the dnstt-deploy script
    log "Installing dnstt-deploy script..."
    bash <(curl -Ls https://raw.githubusercontent.com/bugfloyd/dnstt-deploy/main/dnstt-deploy.sh) --install-only 2>/dev/null || {
        # If that fails, download and install manually
        curl -Ls https://raw.githubusercontent.com/bugfloyd/dnstt-deploy/main/dnstt-deploy.sh -o /usr/local/bin/dnstt-deploy
        chmod +x /usr/local/bin/dnstt-deploy
    }
    
    # Now run the interactive setup by feeding answers via here-document
    log "Running dnstt configuration..."
    
    # Create a response file
    cat > /tmp/dnstt-responses.txt << EOF
${DNS_DOMAIN}
${DNS_MTU}
1
EOF
    
    # Run dnstt-deploy with responses
    /usr/local/bin/dnstt-deploy < /tmp/dnstt-responses.txt || {
        warn "Automated input may have failed, trying alternative method..."
        
        # Alternative: Use expect if available, otherwise manual
        if command -v expect &> /dev/null; then
            install_dnstt_expect
        else
            error "dnstt installation failed. Please run 'dnstt-deploy' manually and then re-run this script with --skip-dnstt flag"
        fi
    }
    
    rm -f /tmp/dnstt-responses.txt
    
    # Verify installation
    sleep 3
    if systemctl is-active --quiet dnstt-server && systemctl is-active --quiet danted; then
        log "dnstt installed successfully"
    else
        error "dnstt installation failed. Check logs: sudo journalctl -u dnstt-server -u danted -n 50"
    fi
}

install_dnstt_expect() {
    log "=== Installing dnstt with expect ==="
    
    # Install expect if needed
    if ! command -v expect &> /dev/null; then
        log "Installing expect..."
        case $OS in
            ubuntu|debian)
                apt-get update -qq
                apt-get install -y expect
                ;;
            centos|rhel|rocky|fedora)
                yum install -y expect
                ;;
        esac
    fi
    
    # Create expect script with longer timeout
    cat > /tmp/dnstt-setup.exp << 'EXPECTEOF'
#!/usr/bin/expect -f
set timeout 600
set domain [lindex $argv 0]
set mtu [lindex $argv 1]

spawn dnstt-deploy

expect {
    "Enter the nameserver subdomain*" {
        send "$domain\r"
        exp_continue
    }
    "Enter the MTU*" {
        send "$mtu\r"
        exp_continue
    }
    "Select tunnel mode*" {
        send "1\r"
        exp_continue
    }
    eof {
        catch wait result
        exit [lindex $result 3]
    }
    timeout {
        puts "Timeout waiting for prompt"
        exit 1
    }
}
EXPECTEOF
    
    chmod +x /tmp/dnstt-setup.exp
    
    # Run with parameters
    /tmp/dnstt-setup.exp "$DNS_DOMAIN" "$DNS_MTU" || {
        error "dnstt installation via expect failed"
    }
    
    rm -f /tmp/dnstt-setup.exp
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
    mkdir -p /usr/local/etc/v2ray
    
    if [[ "$USE_TLS" == "yes" ]]; then
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
    }
  ]
}
EOF
    else
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
      },
      "tag": "dns-tunnel"
    }
  ]
}
EOF
    fi
    
    mkdir -p /var/log/v2ray
    log "V2Ray configuration created"
}

configure_xray_reality() {
    log "=== Configuring Xray (VLESS-Reality) ==="
    
    local config_file="/usr/local/etc/xray/config.json"
    mkdir -p /usr/local/etc/xray
    
    # Generate Reality keys
    local keys_output=$(/usr/local/bin/xray x25519)
    PRIVATE_KEY=$(echo "$keys_output" | grep "Private key:" | awk '{print $3}')
    PUBLIC_KEY=$(echo "$keys_output" | grep "Public key:" | awk '{print $3}')
    SHORT_ID=$(openssl rand -hex 8)
    
    cat > "$config_file" << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${V2RAY_PORT},
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
    
    mkdir -p /var/log/xray
    log "Xray Reality configuration created"
}

configure_xray_trojan() {
    log "=== Configuring Xray (Trojan) ==="
    
    local config_file="/usr/local/etc/xray/config.json"
    mkdir -p /usr/local/etc/xray
    
    if [[ "$USE_TLS" == "yes" ]]; then
        cat > "$config_file" << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${V2RAY_PORT},
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password": "${PASSWORD}"
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
      }
    }
  ]
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
    
    case $OS in
        ubuntu|debian)
            apt-get update -qq
            apt-get install -y certbot
            ;;
        centos|rhel|rocky|fedora)
            yum install -y certbot
            ;;
    esac
    
    systemctl stop v2ray 2>/dev/null || true
    systemctl stop xray 2>/dev/null || true
    
    certbot certonly --standalone --non-interactive --agree-tos \
        --register-unsafely-without-email \
        -d ${V2RAY_DOMAIN} || {
        warn "SSL certificate installation failed."
        USE_TLS="no"
        return
    }
    
    log "SSL certificate installed successfully"
    systemctl enable certbot.timer 2>/dev/null || true
}

configure_firewall() {
    log "=== Configuring Firewall ==="
    
    if command -v ufw &> /dev/null; then
        ufw --force enable
        ufw allow 22/tcp comment 'SSH'
        ufw allow 53/udp comment 'DNS'
        ufw allow ${V2RAY_PORT}/tcp comment 'V2Ray'
        ufw allow 80/tcp comment 'HTTP'
        ufw reload
        log "UFW configured"
    elif command -v firewall-cmd &> /dev/null; then
        systemctl start firewalld
        systemctl enable firewalld
        firewall-cmd --permanent --add-port=22/tcp
        firewall-cmd --permanent --add-port=53/udp
        firewall-cmd --permanent --add-port=${V2RAY_PORT}/tcp
        firewall-cmd --permanent --add-port=80/tcp
        firewall-cmd --reload
        log "FirewallD configured"
    fi
}

enable_bbr() {
    log "=== Enabling BBR ==="
    
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p > /dev/null
        log "BBR enabled"
    fi
}

start_services() {
    log "=== Starting Services ==="
    
    systemctl restart dnstt-server
    systemctl restart danted
    systemctl enable dnstt-server
    systemctl enable danted
    
    case $PROTOCOL in
        v2ray)
            systemctl restart v2ray
            systemctl enable v2ray
            sleep 2
            systemctl is-active --quiet v2ray || error "V2Ray failed to start"
            ;;
        *)
            systemctl restart xray
            systemctl enable xray
            sleep 2
            systemctl is-active --quiet xray || error "Xray failed to start"
            ;;
    esac
    
    log "All services started"
}

verify_installation() {
    log "=== Verifying Installation ==="
    
    systemctl is-active --quiet dnstt-server && log "✓ dnstt-server running" || warn "✗ dnstt-server not running"
    systemctl is-active --quiet danted && log "✓ SOCKS5 running" || warn "✗ SOCKS5 not running"
    
    case $PROTOCOL in
        v2ray)
            systemctl is-active --quiet v2ray && log "✓ V2Ray running" || warn "✗ V2Ray not running"
            ;;
        *)
            systemctl is-active --quiet xray && log "✓ Xray running" || warn "✗ Xray not running"
            ;;
    esac
}

generate_vmess_link() {
    local json="{\"v\":\"2\",\"ps\":\"${PROXY_NAME}\",\"add\":\"${SERVER_IP}\",\"port\":\"${V2RAY_PORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"net\":\"$([ "$USE_TLS" == "yes" ] && echo "ws" || echo "tcp")\",\"type\":\"none\",\"host\":\"${V2RAY_DOMAIN}\",\"path\":\"$([ "$USE_TLS" == "yes" ] && echo "/vmess" || echo "")\",\"tls\":\"$([ "$USE_TLS" == "yes" ] && echo "tls" || echo "")\"}"
    echo "vmess://$(echo -n "$json" | base64 -w 0)"
}

generate_vless_link() {
    echo "vless://${UUID}@${SERVER_IP}:${V2RAY_PORT}?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#${PROXY_NAME// /%20}"
}

generate_trojan_link() {
    echo "trojan://${PASSWORD}@${V2RAY_DOMAIN}:${V2RAY_PORT}?security=tls&sni=${V2RAY_DOMAIN}&type=tcp#${PROXY_NAME// /%20}"
}

save_configuration() {
    local config_dir="/root/dnstt-v2ray-config"
    mkdir -p "$config_dir"
    
    case $PROTOCOL_CHOICE in
        1) CLIENT_LINK=$(generate_vmess_link) ;;
        2) CLIENT_LINK=$(generate_vless_link) ;;
        3) CLIENT_LINK=$(generate_trojan_link) ;;
    esac
    
    cat > "$config_dir/client-info.txt" << EOF
=======================================================
  Client Configuration
=======================================================

Protocol: ${PROTOCOL_NAME}
Server: ${SERVER_IP}
Port: ${V2RAY_PORT}
UUID: ${UUID}
$([ "$PROTOCOL_CHOICE" == "3" ] && echo "Password: ${PASSWORD}")
$([ "$PROTOCOL_CHOICE" == "2" ] && echo "Public Key: ${PUBLIC_KEY}")
$([ "$PROTOCOL_CHOICE" == "2" ] && echo "Short ID: ${SHORT_ID}")

Connection Link:
${CLIENT_LINK}

=======================================================
EOF
    
    log "Configuration saved to: $config_dir"
}

display_results() {
    echo ""
    echo -e "${GREEN}╔═════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   🎉 Installation Completed Successfully!   ║${NC}"
    echo -e "${GREEN}╚═════════════════════════════════════════════╝${NC}"
    echo ""
    
    echo -e "${BLUE}Protocol:${NC} $PROTOCOL_NAME"
    echo -e "${BLUE}Server:${NC} $SERVER_IP:$V2RAY_PORT"
    echo ""
    echo -e "${YELLOW}Connection Link:${NC}"
    echo "$CLIENT_LINK"
    echo ""
    echo "Configuration saved: /root/dnstt-v2ray-config/client-info.txt"
    echo ""
}

main() {
    print_banner
    check_root
    detect_os
    collect_user_input
    
    install_dnstt_manual
    
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
    
    configure_firewall
    enable_bbr
    start_services
    verify_installation
    save_configuration
    display_results
}

main "$@"
