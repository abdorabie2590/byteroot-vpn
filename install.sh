#!/bin/bash
# =====================================================================
#  ByteRoot VPN Multi-Protocol Installer
#  Dev. Eng Abdelrahman Rabie | Telegram: @PacketBreaker
#  Supports: OpenSSH, SSH-Websocket, SSH-Stunnel(SSL/TLS), BadVPN(UDPGW),
#            Nginx, Vmess/Vless/Trojan (WS+TLS / WS NoTLS) via Xray-core
#  OS: Ubuntu 22 - 26 | Debian 10+   |   Arch: x86_64 / arm64 (Oracle A1)
# =====================================================================
set -e

RED='\e[31m'; GREEN='\e[32m'; YELLOW='\e[33m'; CYAN='\e[36m'; NC='\e[0m'

banner() {
clear
echo -e "${CYAN}"
cat <<"EOF"
 ____        _       ____             _
| __ ) _   _| |_ ___|  _ \ ___   ___ | |_
|  _ \| | | | __/ _ \ |_) / _ \ / _ \| __|
| |_) | |_| | ||  __/  _ < (_) | (_) | |_
|____/ \__, |\__\___|_| \_\___/ \___/ \__|
       |___/
EOF
echo -e "${NC}"
echo -e "${YELLOW}          ByteRoot VPN Multi-Protocol Installer${NC}"
echo -e "${YELLOW}          Dev. Eng Abdelrahman Rabie | Telegram: @PacketBreaker${NC}"
echo "======================================================="
}

banner

# ---------------------------------------------------------------
# 0) Root & OS / Arch check
# ---------------------------------------------------------------
if [ "$(id -u)" != "0" ]; then
  echo -e "${RED}[!] Please run this script as root (sudo -i)${NC}"
  exit 1
fi

source /etc/os-release
OS_ID="$ID"
ARCH_RAW=$(uname -m)

if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
  echo -e "${RED}[!] This script only supports Ubuntu / Debian${NC}"
  exit 1
fi

case "$ARCH_RAW" in
  x86_64|amd64)  ARCH_LABEL="x86_64 (amd64)" ;;
  aarch64|arm64) ARCH_LABEL="arm64/aarch64 (Oracle A1 / Ampere compatible)" ;;
  *) ARCH_LABEL="$ARCH_RAW" ;;
esac

echo -e "${GREEN}[i] Detected OS   : $PRETTY_NAME"
echo -e "[i] Architecture  : $ARCH_LABEL${NC}"
echo -e "${CYAN}[i] Supports Ubuntu 22-26 and Debian 10+, on x86_64 and arm64 (Oracle A1 Always Free).${NC}"
sleep 1

mkdir -p /etc/byteroot
INFO_FILE="/root/byteroot-info.txt"
echo "ByteRoot VPN - Server Info | Dev. Eng Abdelrahman Rabie | Telegram: @PacketBreaker" > "$INFO_FILE"
echo "Generated: $(date)" >> "$INFO_FILE"
echo "=====================================================" >> "$INFO_FILE"

# ---------------------------------------------------------------
# 1) Ask for Domain
# ---------------------------------------------------------------
read -rp $'\n'"${CYAN}[?] Enter your domain (example: vpn.example.com): ${NC}" DOMAIN
if [ -z "$DOMAIN" ]; then
  echo -e "${RED}[!] A domain is required${NC}"; exit 1
fi

SERVER_IP=$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com)
DOMAIN_IP=$(getent ahostsv4 "$DOMAIN" | awk '{print $1; exit}')

echo -e "${YELLOW}[i] Server IP: $SERVER_IP"
echo -e "[i] Domain IP: $DOMAIN_IP${NC}"

if [ "$SERVER_IP" != "$DOMAIN_IP" ]; then
  echo -e "${RED}[!] Warning: this domain does not currently point (A Record) to this server's IP.${NC}"
  read -rp "Continue anyway? (y/n): " CONT
  if [ "$CONT" != "y" ]; then
    echo "Point the domain's A Record to $SERVER_IP then re-run this script."
    exit 1
  fi
fi

echo "Domain: $DOMAIN"  >> "$INFO_FILE"
echo "Server IP: $SERVER_IP" >> "$INFO_FILE"
mkdir -p /etc/byteroot/db /etc/byteroot/scripts
echo "$DOMAIN" > /etc/byteroot/domain
touch /etc/byteroot/db/ssh.db /etc/byteroot/db/vmess.db /etc/byteroot/db/vless.db /etc/byteroot/db/trojan.db

# ---------------------------------------------------------------
# 2) Base packages
# ---------------------------------------------------------------
echo -e "${CYAN}[+] Updating system and installing base packages...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt update -y && apt upgrade -y
apt install -y curl wget socat cron unzip git jq ufw \
  nginx-full stunnel4 haproxy certbot python3 python3-pip build-essential \
  net-tools lsof gnupg2 ca-certificates software-properties-common

systemctl enable cron
systemctl start cron

# ---------------------------------------------------------------
# 3) Firewall
# ---------------------------------------------------------------
echo -e "${CYAN}[+] Configuring firewall (UFW)...${NC}"
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 81/tcp
ufw allow 443/tcp
ufw allow 442/tcp
ufw allow 8080/tcp
ufw allow 7100:7900/udp
ufw allow 7100:7900/tcp
ufw --force enable

# ---------------------------------------------------------------
# 4) SSH banner
# ---------------------------------------------------------------
echo -e "${CYAN}[+] Configuring OpenSSH...${NC}"
cat > /etc/issue.net <<EOF
======================================
   Welcome to ByteRoot VPN Server
   Dev. Eng Abdelrahman Rabie | Telegram: @PacketBreaker
======================================
EOF
if ! grep -q "Banner /etc/issue.net" /etc/ssh/sshd_config; then
  echo "Banner /etc/issue.net" >> /etc/ssh/sshd_config
fi
systemctl restart ssh || systemctl restart sshd

# ---------------------------------------------------------------
# 5) SSL certificate (Let's Encrypt) - standalone, needs port 80 free
# ---------------------------------------------------------------
echo -e "${CYAN}[+] Issuing SSL certificate for $DOMAIN ...${NC}"
systemctl stop nginx 2>/dev/null || true
fuser -k 80/tcp 2>/dev/null || true

certbot certonly --standalone --non-interactive --agree-tos \
  -m admin@"$DOMAIN" -d "$DOMAIN" || {
    echo -e "${RED}[!] Let's Encrypt issuance failed, generating a self-signed certificate instead.${NC}"
    mkdir -p /etc/letsencrypt/live/"$DOMAIN"
    openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
      -keyout /etc/letsencrypt/live/"$DOMAIN"/privkey.pem \
      -out /etc/letsencrypt/live/"$DOMAIN"/fullchain.pem \
      -subj "/CN=$DOMAIN"
  }

CERT_DIR="/etc/letsencrypt/live/$DOMAIN"

cat > /etc/letsencrypt/renewal-hooks/deploy/byteroot-reload.sh <<EOF
#!/bin/bash
systemctl reload nginx
systemctl restart stunnel4
systemctl restart xray
systemctl restart haproxy
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/byteroot-reload.sh

# ---------------------------------------------------------------
# 6) Install Xray-core (Vmess / Vless / Trojan) + Stats API
#    Robust install: tries the official script first, then falls back
#    to a direct GitHub release download (bypasses GitHub API rate
#    limiting, which is a common real-world cause of silent install
#    failures -> permanently "failed" xray service).
# ---------------------------------------------------------------
echo -e "${CYAN}[+] Installing Xray-core ...${NC}"

install_xray_official() {
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/tmp/xray_install.log 2>&1
}

install_xray_fallback() {
  echo -e "${YELLOW}[!] Official installer unavailable or failed (often due to GitHub API rate limits). Falling back to direct release download...${NC}"
  case "$ARCH_RAW" in
    x86_64|amd64)  XRAY_ASSET="Xray-linux-64.zip" ;;
    aarch64|arm64) XRAY_ASSET="Xray-linux-arm64-v8a.zip" ;;
    *) echo -e "${RED}[!] Unsupported architecture for fallback install: $ARCH_RAW${NC}"; return 1 ;;
  esac

  # Resolve the latest release tag WITHOUT hitting the GitHub API (avoids rate limiting):
  # the /releases/latest URL 302-redirects to /releases/tag/<version>
  XRAY_TAG=$(curl -s -o /dev/null -w '%{redirect_url}' https://github.com/XTLS/Xray-core/releases/latest | sed 's#.*/tag/##')
  [ -z "$XRAY_TAG" ] && XRAY_TAG="v26.3.27"   # last-known-good pinned fallback if redirect resolution fails too

  echo -e "${CYAN}[i] Installing Xray-core $XRAY_TAG ($XRAY_ASSET)${NC}"
  TMP_XRAY=$(mktemp -d)
  if ! curl -fsSL -o "$TMP_XRAY/xray.zip" "https://github.com/XTLS/Xray-core/releases/download/$XRAY_TAG/$XRAY_ASSET"; then
    echo -e "${RED}[!] Fallback download failed too. Check network/firewall access to github.com.${NC}"
    return 1
  fi

  unzip -o -q "$TMP_XRAY/xray.zip" -d "$TMP_XRAY"
  install -m 755 "$TMP_XRAY/xray" /usr/local/bin/xray
  mkdir -p /usr/local/share/xray /usr/local/etc/xray
  cp -f "$TMP_XRAY/geoip.dat" "$TMP_XRAY/geosite.dat" /usr/local/share/xray/ 2>/dev/null || true
  rm -rf "$TMP_XRAY"

  id xray &>/dev/null || useradd -r -s /usr/sbin/nologin xray 2>/dev/null || true
  mkdir -p /var/log/xray
  chown -R xray:xray /var/log/xray /usr/local/etc/xray 2>/dev/null || true

  cat > /etc/systemd/system/xray.service <<'XSVC'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
XSVC
  systemctl daemon-reload
}

if install_xray_official && command -v xray >/dev/null 2>&1 && xray version >/dev/null 2>&1; then
  echo -e "${GREEN}[✓] Xray-core installed via the official installer.${NC}"
else
  install_xray_fallback
fi

if ! command -v xray >/dev/null 2>&1 || ! xray version >/dev/null 2>&1; then
  echo -e "${RED}[!] Xray-core installation failed completely. Vmess/Vless/Trojan will NOT work.${NC}"
  echo -e "${RED}    Check /tmp/xray_install.log and your server's outbound access to github.com.${NC}"
fi

UUID_VMESS=$(cat /proc/sys/kernel/random/uuid)
UUID_VLESS=$(cat /proc/sys/kernel/random/uuid)
TROJAN_PASS=$(openssl rand -hex 8)

mkdir -p /usr/local/etc/xray
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "api": {
    "tag": "api",
    "services": ["HandlerService", "StatsService"]
  },
  "stats": {},
  "policy": {
    "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true } },
    "system": { "statsInboundUplink": true, "statsInboundDownlink": true }
  },
  "inbounds": [
    {
      "tag": "api-in",
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" }
    },
    {
      "tag": "vmess-ws",
      "listen": "127.0.0.1",
      "port": 4431,
      "protocol": "vmess",
      "settings": { "clients": [ { "id": "$UUID_VMESS", "alterId": 0, "email": "default-vmess" } ] },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vmess" }
      }
    },
    {
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "port": 4432,
      "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID_VLESS", "email": "default-vless" } ], "decryption": "none" },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vless" }
      }
    },
    {
      "tag": "trojan-ws",
      "listen": "127.0.0.1",
      "port": 4433,
      "protocol": "trojan",
      "settings": { "clients": [ { "password": "$TROJAN_PASS", "email": "default-trojan" } ] },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/trojan" }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ],
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": ["api-in"], "outboundTag": "api" }
    ]
  }
}
EOF

systemctl enable xray >/dev/null 2>&1

echo -e "${CYAN}[+] Validating Xray configuration ...${NC}"
if /usr/local/bin/xray run -test -format json -config /usr/local/etc/xray/config.json 2>&1 | tee /tmp/xray_test.log | grep -q "Configuration OK"; then
  echo -e "${GREEN}[✓] Xray configuration is valid.${NC}"
else
  echo -e "${RED}[!] Xray configuration test FAILED. Details:${NC}"
  cat /tmp/xray_test.log
fi

systemctl restart xray
sleep 1
if systemctl is-active --quiet xray; then
  echo -e "${GREEN}[✓] Xray service is running.${NC}"
else
  echo -e "${RED}[!] Xray service FAILED to start. Diagnostic output:${NC}"
  systemctl status xray --no-pager -l | tail -15
  journalctl -u xray -n 20 --no-pager
fi

{
echo ""
echo "----------------- Vmess / Vless / Trojan (default accounts) -----------------"
echo "Domain      : $DOMAIN"
echo "Vmess  UUID : $UUID_VMESS   | Path: /vmess | Local: 127.0.0.1:4431 | Ports: 80 (NoTLS) / 443 (TLS)"
echo "Vless  UUID : $UUID_VLESS   | Path: /vless | Local: 127.0.0.1:4432 | Ports: 80 (NoTLS) / 443 (TLS)"
echo "Trojan Pass : $TROJAN_PASS  | Path: /trojan| Local: 127.0.0.1:4433 | Ports: 80 (NoTLS) / 443 (TLS)"
echo "Use the 'byteroot' panel -> option 9 to see these as ready-to-import links."
} >> "$INFO_FILE"

# ---------------------------------------------------------------
# 7) SSH - Websocket proxy (python) -> local SSH:22
# ---------------------------------------------------------------
echo -e "${CYAN}[+] Setting up SSH Websocket Proxy ...${NC}"
mkdir -p /etc/byteroot
cat > /etc/byteroot/ws-ssh-proxy.py <<'PYEOF'
#!/usr/bin/env python3
import socket, threading, sys

LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8880
SSH_HOST = "127.0.0.1"
SSH_PORT = 22
RESPONSE = b"HTTP/1.1 101 Switching Protocols\r\n\r\n"

def handle(client):
    try:
        client.recv(4096)  # consume the fake HTTP/WS upgrade request
        client.send(RESPONSE)
        target = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        target.connect((SSH_HOST, SSH_PORT))

        def pipe(a, b):
            try:
                while True:
                    data = a.recv(4096)
                    if not data:
                        break
                    b.send(data)
            except Exception:
                pass
            finally:
                a.close(); b.close()

        threading.Thread(target=pipe, args=(client, target), daemon=True).start()
        pipe(target, client)
    except Exception:
        try: client.close()
        except Exception: pass

def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", LISTEN_PORT))
    srv.listen(200)
    print(f"[ByteRoot] SSH-WS proxy listening on {LISTEN_PORT} -> {SSH_HOST}:{SSH_PORT}")
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()

if __name__ == "__main__":
    main()
PYEOF
chmod +x /etc/byteroot/ws-ssh-proxy.py

cat > /etc/systemd/system/byteroot-wsssh-internal.service <<EOF
[Unit]
Description=ByteRoot SSH-WS Proxy (internal, backend for nginx)
After=network.target
[Service]
ExecStart=/usr/bin/python3 /etc/byteroot/ws-ssh-proxy.py 8880
Restart=always
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/byteroot-wsssh-8080.service <<EOF
[Unit]
Description=ByteRoot SSH-WS Proxy (direct, port 8080)
After=network.target
[Service]
ExecStart=/usr/bin/python3 /etc/byteroot/ws-ssh-proxy.py 8080
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable byteroot-wsssh-internal byteroot-wsssh-8080
systemctl restart byteroot-wsssh-internal byteroot-wsssh-8080

# ---------------------------------------------------------------
# 8) Stunnel (SSL wrapper for SSH) - port 442 (direct) + 445 (internal, via HAProxy on 443)
# ---------------------------------------------------------------
echo -e "${CYAN}[+] Configuring Stunnel (SSH SSL/TLS) on port 442 ...${NC}"
cat "$CERT_DIR/fullchain.pem" "$CERT_DIR/privkey.pem" > /etc/stunnel/stunnel.pem

cat > /etc/stunnel/stunnel.conf <<EOF
pid = /var/run/stunnel4.pid
cert = /etc/stunnel/stunnel.pem
client = no
socket = a:SO_REUSEADDR=1
socket = l:TCP_NODELAY=1

[ssh-ssl]
accept = 442
connect = 127.0.0.1:22

; internal listener used by HAProxy when it forwards SSH-SSL traffic
; that arrives on the shared public port 443 (no/foreign SNI)
[ssh-ssl-internal]
accept = 127.0.0.1:445
connect = 127.0.0.1:22
EOF

sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4 2>/dev/null || echo "ENABLED=1" > /etc/default/stunnel4
systemctl enable stunnel4
systemctl restart stunnel4

# ---------------------------------------------------------------
# 9) BadVPN (UDPGW) - ports 7100-7900
# ---------------------------------------------------------------
echo -e "${CYAN}[+] Installing BadVPN UDPGW ...${NC}"
if [ ! -f /usr/bin/badvpn-udpgw ]; then
  apt install -y cmake > /dev/null 2>&1
  cd /root
  git clone --depth=1 https://github.com/ambrop72/badvpn.git 2>/dev/null || true
  if [ -d /root/badvpn ]; then
    mkdir -p /root/badvpn/build && cd /root/badvpn/build
    cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 > /dev/null
    make -j"$(nproc)" > /dev/null
    cp udpgw/badvpn-udpgw /usr/bin/badvpn-udpgw
  fi
fi

cat > /etc/systemd/system/badvpn-udpgw@.service <<EOF
[Unit]
Description=ByteRoot BadVPN UDPGW on port %i
After=network.target

[Service]
ExecStart=/usr/bin/badvpn-udpgw --listen-addr 0.0.0.0:%i --max-clients 500 --max-connections-for-client 10
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

for p in 7100 7200 7300 7400 7500 7600 7700 7800 7900; do
  systemctl enable badvpn-udpgw@"$p" > /dev/null 2>&1
  systemctl restart badvpn-udpgw@"$p" > /dev/null 2>&1
done
echo "BadVPN active ports: 7100,7200,7300,7400,7500,7600,7700,7800,7900 (full range 7100-7900 available via: systemctl start badvpn-udpgw@<port>)" >> "$INFO_FILE"

# ---------------------------------------------------------------
# 10) Nginx - reverse proxy for 80 / 81 / 443(internal)
# ---------------------------------------------------------------
echo -e "${CYAN}[+] Configuring Nginx (80 / 81 / internal 443) ...${NC}"

cat > /etc/nginx/conf.d/byteroot.conf <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

# ---- Port 80 : SSH-WS (default) + Vmess/Vless/Trojan (No TLS) ----
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location /vmess {
        proxy_pass http://127.0.0.1:4431;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
    }
    location /vless {
        proxy_pass http://127.0.0.1:4432;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
    }
    location /trojan {
        proxy_pass http://127.0.0.1:4433;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
    }
    location / {
        proxy_pass http://127.0.0.1:8880;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
    }
}

# ---- Port 81 : mirror of 80 ----
server {
    listen 81;
    listen [::]:81;
    server_name $DOMAIN;

    location /vmess { proxy_pass http://127.0.0.1:4431; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \$connection_upgrade; proxy_set_header Host \$host; }
    location /vless { proxy_pass http://127.0.0.1:4432; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \$connection_upgrade; proxy_set_header Host \$host; }
    location /trojan { proxy_pass http://127.0.0.1:4433; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \$connection_upgrade; proxy_set_header Host \$host; }
    location / { proxy_pass http://127.0.0.1:8880; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \$connection_upgrade; proxy_set_header Host \$host; }
}

# ---- Port 443 (internal, behind HAProxy) : Vmess/Vless/Trojan (WS + TLS) ----
server {
    listen 127.0.0.1:8443 ssl;
    server_name $DOMAIN;

    ssl_certificate     $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location /vmess {
        proxy_pass http://127.0.0.1:4431;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
    }
    location /vless {
        proxy_pass http://127.0.0.1:4432;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
    }
    location /trojan {
        proxy_pass http://127.0.0.1:4433;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
    }
    location / {
        return 404;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

nginx -t
systemctl enable nginx
systemctl restart nginx

# ---------------------------------------------------------------
# 10.5) HAProxy - shares public port 443 between Nginx(WS-TLS) & Stunnel(SSH-SSL)
#       by inspecting the TLS SNI (no decryption needed).
# ---------------------------------------------------------------
echo -e "${CYAN}[+] Configuring HAProxy to share port 443 between Nginx and Stunnel ...${NC}"

cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    maxconn 4096
    daemon

defaults
    log     global
    mode    tcp
    timeout connect 5s
    timeout client  1h
    timeout server  1h

frontend ft_443
    bind *:443
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }

    # SNI matches our domain -> Nginx (Vmess/Vless/Trojan TLS)
    use_backend bk_nginx_tls if { req.ssl_sni -i $DOMAIN }

    # anything else (no SNI / different SNI, typical of SSH-SSL clients) -> Stunnel
    default_backend bk_stunnel_ssh

backend bk_nginx_tls
    mode tcp
    server nginx1 127.0.0.1:8443

backend bk_stunnel_ssh
    mode tcp
    server stunnel1 127.0.0.1:445
EOF

systemctl enable haproxy
systemctl restart haproxy

# ---------------------------------------------------------------
# 11) ByteRoot Enforcement Engine (expiry + quota + connection limits)
# ---------------------------------------------------------------
echo -e "${CYAN}[+] Setting up the enforcement engine (expiry / quota / connection limits) ...${NC}"

cat > /etc/byteroot/scripts/enforce.sh <<'ENFEOF'
#!/bin/bash
# ByteRoot - expiry & quota enforcement (runs via cron every 5 min)
DB=/etc/byteroot/db
SSH_DB="$DB/ssh.db"
XRAY_CONFIG=/usr/local/etc/xray/config.json
TODAY=$(date +%Y-%m-%d)
NEED_RESTART=0

# ---- SSH accounts ----
if [ -s "$SSH_DB" ]; then
  tmp=$(mktemp)
  while IFS='|' read -r user type maxconn quota expiry created status; do
    [ -z "$user" ] && continue
    if [ "$status" == "locked" ]; then
      echo "$user|$type|$maxconn|$quota|$expiry|$created|locked" >> "$tmp"
      continue
    fi
    expired=0
    if [ "$expiry" != "-" ] && [ "$expiry" \< "$TODAY" ]; then expired=1; fi
    overquota=0
    if [ "$quota" != "0" ] && [ -n "$quota" ]; then
      bytes=$(iptables -L "br_$user" -v -x -n 2>/dev/null | awk '/RETURN/{print $2; exit}')
      [ -z "$bytes" ] && bytes=0
      limitbytes=$(( quota * 1073741824 ))
      [ "$bytes" -ge "$limitbytes" ] && overquota=1
    fi
    if [ "$expired" == "1" ] || [ "$overquota" == "1" ]; then
      usermod -L "$user" 2>/dev/null
      chage -E 1 "$user" 2>/dev/null
      pkill -9 -u "$user" 2>/dev/null
      logger "ByteRoot: SSH account $user LOCKED (expired=$expired overquota=$overquota)"
      echo "$user|$type|$maxconn|$quota|$expiry|$created|locked" >> "$tmp"
    else
      echo "$user|$type|$maxconn|$quota|$expiry|$created|$status" >> "$tmp"
    fi
  done < "$SSH_DB"
  mv "$tmp" "$SSH_DB"
fi

# ---- Xray accounts (vmess / vless / trojan) ----
for proto in vmess vless trojan; do
  db="$DB/$proto.db"
  tag="$proto-ws"
  [ -s "$db" ] || continue
  tmp=$(mktemp)
  while IFS='|' read -r name cred type maxconn quota expiry created status; do
    [ -z "$name" ] && continue
    if [ "$status" == "removed" ]; then
      echo "$name|$cred|$type|$maxconn|$quota|$expiry|$created|removed" >> "$tmp"
      continue
    fi
    expired=0
    if [ "$expiry" != "-" ] && [ "$expiry" \< "$TODAY" ]; then expired=1; fi
    overquota=0
    if [ "$quota" != "0" ] && [ -n "$quota" ]; then
      stat=$(xray api statsquery --server=127.0.0.1:10085 -pattern "user>>>$name>>>traffic" 2>/dev/null)
      total=$(echo "$stat" | jq '[.stat[]?.value] | add // 0' 2>/dev/null)
      [ -z "$total" ] && total=0
      limitbytes=$(( quota * 1073741824 ))
      [ "$total" -ge "$limitbytes" ] && overquota=1
    fi
    if [ "$expired" == "1" ] || [ "$overquota" == "1" ]; then
      jq --arg tag "$tag" --arg id "$cred" \
        '(.inbounds[] | select(.tag==$tag) | .settings.clients) |= map(select((.id // "") != $id and (.password // "") != $id))' \
        "$XRAY_CONFIG" > /tmp/br_xray.json
      if /usr/local/bin/xray run -test -format json -config /tmp/br_xray.json >/dev/null 2>&1; then
        mv /tmp/br_xray.json "$XRAY_CONFIG"
        NEED_RESTART=1
        logger "ByteRoot: $proto account $name REMOVED (expired=$expired overquota=$overquota)"
      else
        logger "ByteRoot: FAILED to remove $proto account $name - resulting config invalid, kept as-is"
        rm -f /tmp/br_xray.json
      fi
      echo "$name|$cred|$type|$maxconn|$quota|$expiry|$created|removed" >> "$tmp"
    else
      echo "$name|$cred|$type|$maxconn|$quota|$expiry|$created|$status" >> "$tmp"
    fi
  done < "$db"
  mv "$tmp" "$db"
done

[ "$NEED_RESTART" == "1" ] && systemctl restart xray
ENFEOF
chmod +x /etc/byteroot/scripts/enforce.sh

cat > /etc/byteroot/scripts/conn_limit.sh <<'CONNEOF'
#!/bin/bash
# ByteRoot - best-effort concurrent SSH connection limiter (runs via cron every minute)
DB=/etc/byteroot/db/ssh.db
[ -s "$DB" ] || exit 0
while IFS='|' read -r user type maxconn quota expiry created status; do
  [ -z "$user" ] && continue
  [ "$status" == "locked" ] && continue
  [ -z "$maxconn" ] && continue
  [ "$maxconn" == "0" ] && continue
  current=$(ps -eo user:32,pid,cmd | awk -v u="$user" '$1==u && $0 ~ /sshd:/{print $2}' | wc -l)
  if [ "$current" -gt "$maxconn" ]; then
    excess=$(( current - maxconn ))
    ps -eo user:32,pid,cmd | awk -v u="$user" '$1==u && $0 ~ /sshd:/{print $2}' | head -n "$excess" | while read -r pid; do
      kill -9 "$pid" 2>/dev/null
    done
    logger "ByteRoot: killed $excess excess SSH session(s) for $user (limit=$maxconn)"
  fi
done < "$DB"
CONNEOF
chmod +x /etc/byteroot/scripts/conn_limit.sh

( crontab -l 2>/dev/null | grep -v 'byteroot/scripts' ; \
  echo "*/5 * * * * /etc/byteroot/scripts/enforce.sh >/dev/null 2>&1" ; \
  echo "* * * * * /etc/byteroot/scripts/conn_limit.sh >/dev/null 2>&1" \
) | crontab -

# ---------------------------------------------------------------
# 12) ByteRoot Management Panel (/usr/local/bin/byteroot)
# ---------------------------------------------------------------
echo -e "${CYAN}[+] Installing the ByteRoot management panel ...${NC}"

cat > /usr/local/bin/byteroot <<'MENUEOF'
#!/bin/bash
# =====================================================================
#  ByteRoot VPN Management Panel
#  Dev. Eng Abdelrahman Rabie | Telegram: @PacketBreaker
# =====================================================================

DB=/etc/byteroot/db
SSH_DB="$DB/ssh.db"
VMESS_DB="$DB/vmess.db"
VLESS_DB="$DB/vless.db"
TROJAN_DB="$DB/trojan.db"
XRAY_CONFIG=/usr/local/etc/xray/config.json
DOMAIN=$(cat /etc/byteroot/domain 2>/dev/null)
INFO_FILE=/root/byteroot-info.txt

RED='\e[91m'; GREEN='\e[92m'; YELLOW='\e[93m'; CYAN='\e[96m'; MAGENTA='\e[95m'; BOLD='\e[1m'; NC='\e[0m'

pause(){ read -rp $'\n'"Press Enter to go back..." _; }
count_db(){ [ -f "$1" ] && { grep -vc '^[[:space:]]*$' "$1" 2>/dev/null || true; } || echo 0; }

# Validate a candidate xray config before applying it; refuses to apply
# (and keeps the previous working config) if it doesn't pass "xray run -test".
apply_xray_config(){
  local candidate="$1"
  if /usr/local/bin/xray run -test -format json -config "$candidate" >/tmp/xray_test.log 2>&1; then
    mv "$candidate" "$XRAY_CONFIG"
    systemctl restart xray
    sleep 1
    if systemctl is-active --quiet xray; then
      return 0
    else
      echo -e "${RED}Xray failed to start after this change. Recent log:${NC}"
      journalctl -u xray -n 15 --no-pager
      return 1
    fi
  else
    echo -e "${RED}Change rejected: invalid Xray configuration, previous config kept.${NC}"
    cat /tmp/xray_test.log
    rm -f "$candidate"
    return 1
  fi
}

online_ssh_count(){
  ss -tn state established 2>/dev/null | awk '{print $4}' | grep -E ':(22|442|8080)$' | wc -l
}

banner(){
clear
echo -e "${CYAN}${BOLD}"
cat <<"LOGO"
 ____        _       ____             _
| __ ) _   _| |_ ___|  _ \ ___   ___ | |_
|  _ \| | | | __/ _ \ |_) / _ \ / _ \| __|
| |_) | |_| | ||  __/  _ < (_) | (_) | |_
|____/ \__, |\__\___|_| \_\___/ \___/ \__|
       |___/
LOGO
echo -e "${NC}"
echo -e "${YELLOW}${BOLD}            ByteRoot VPN Management Panel${NC}"
echo -e "${MAGENTA}     Dev. Eng Abdelrahman Rabie   |   Telegram: @PacketBreaker${NC}"
echo -e "${CYAN}=====================================================================${NC}"
echo -e "${GREEN} Date & Time     : $(date '+%Y-%m-%d  %H:%M:%S')${NC}"
echo -e " Domain          : ${DOMAIN:-not set}"
if [ -f /etc/os-release ]; then . /etc/os-release; echo " OS / Arch       : $PRETTY_NAME | $(uname -m)"; fi
echo -e "${CYAN}---------------------------------------------------------------------${NC}"
echo -e " Online now (SSH)          : ${YELLOW}$(online_ssh_count)${NC}"
echo -e " SSH accounts              : ${GREEN}$(count_db "$SSH_DB")${NC}"
echo -e " Vmess accounts            : ${GREEN}$(count_db "$VMESS_DB")${NC}"
echo -e " Vless accounts            : ${GREEN}$(count_db "$VLESS_DB")${NC}"
echo -e " Trojan accounts           : ${GREEN}$(count_db "$TROJAN_DB")${NC}"
echo -e "${CYAN}=====================================================================${NC}"
}

ask_limits(){
  # sets global vars: TYPE MAXCONN QUOTA DAYS
  echo " 1) Unlimited (Free) account - no restrictions"
  echo " 2) Limited account (connections / GB / days)"
  read -rp " Choose account type: " t
  MAXCONN=0; QUOTA=0; DAYS=0; TYPE="unlimited"
  if [ "$t" == "2" ]; then
    TYPE="limited"
    read -rp " Max concurrent connections (0 = unlimited): " MAXCONN
    read -rp " Data quota in GB (0 = unlimited): " QUOTA
    read -rp " Expiry in days (0 = never expires): " DAYS
    [ -z "$MAXCONN" ] && MAXCONN=0
    [ -z "$QUOTA" ] && QUOTA=0
    [ -z "$DAYS" ] && DAYS=0
  fi
}

# ---------------- SSH ----------------
create_ssh_account(){
  banner; echo -e "${BOLD}--- 1) Create New SSH Account ---${NC}"
  read -rp " Username: " uname
  if [ -z "$uname" ] || id "$uname" &>/dev/null; then echo -e "${RED}Invalid or already exists${NC}"; pause; return; fi
  read -rp " Password (blank = auto-generate): " pass
  [ -z "$pass" ] && pass=$(openssl rand -base64 9)
  ask_limits

  useradd -M -s /usr/sbin/nologin "$uname"
  echo "$uname:$pass" | chpasswd

  expiry="-"
  if [ "$DAYS" != "0" ]; then
    expiry=$(date -d "+$DAYS days" +%Y-%m-%d)
    chage -E "$expiry" "$uname"
  fi

  if [ "$MAXCONN" != "0" ]; then
    mkdir -p /etc/security/limits.d
    sed -i "/^$uname /d" /etc/security/limits.d/byteroot.conf 2>/dev/null
    echo "$uname hard maxlogins $MAXCONN" >> /etc/security/limits.d/byteroot.conf
  fi

  if [ "$QUOTA" != "0" ]; then
    uid=$(id -u "$uname")
    iptables -N "br_$uname" 2>/dev/null
    iptables -I OUTPUT -m owner --uid-owner "$uid" -j "br_$uname" 2>/dev/null
    iptables -A "br_$uname" -j RETURN 2>/dev/null
  fi

  echo "$uname|$TYPE|$MAXCONN|$QUOTA|$expiry|$(date +%Y-%m-%d)|active" >> "$SSH_DB"

  banner
  echo -e "${GREEN}SSH account created successfully ✅${NC}"
  echo "-----------------------------------"
  echo " Username : $uname"
  echo " Password : $pass"
  echo " Domain   : $DOMAIN"
  echo " Ports    : 22 (SSH) | 442/443 (SSL) | 80/8080 (WS)"
  echo " Type     : $TYPE"
  [ "$TYPE" == "limited" ] && echo " Limits   : Conn=$MAXCONN | Quota=${QUOTA}GB | Expiry=$expiry"
  pause
}

list_ssh_accounts(){
  banner; echo -e "${BOLD}--- SSH Accounts List ---${NC}"
  printf "%-15s %-10s %-6s %-6s %-12s %-10s\n" "Username" "Type" "Conn" "GB" "Expiry" "Status"
  echo "----------------------------------------------------------------------"
  [ -s "$SSH_DB" ] && while IFS='|' read -r u t m q e c s; do
    [ -z "$u" ] && continue
    used=$(iptables -L "br_$u" -v -x -n 2>/dev/null | awk '/RETURN/{printf "%.2f", $2/1073741824; exit}')
    [ -z "$used" ] && used="0.00"
    printf "%-15s %-10s %-6s %-6s %-12s %-10s (Used: %sGB)\n" "$u" "$t" "$m" "$q" "$e" "$s" "$used"
  done < "$SSH_DB"
  pause
}

delete_ssh_account(){
  banner; echo -e "${BOLD}--- Delete SSH Account ---${NC}"
  read -rp " Username to delete: " uname
  if ! id "$uname" &>/dev/null; then echo -e "${RED}Not found${NC}"; pause; return; fi
  userdel -rf "$uname" 2>/dev/null
  iptables -F "br_$uname" 2>/dev/null; iptables -D OUTPUT -m owner --uid-owner "$(id -u "$uname" 2>/dev/null)" -j "br_$uname" 2>/dev/null; iptables -X "br_$uname" 2>/dev/null
  sed -i "/^$uname /d" /etc/security/limits.d/byteroot.conf 2>/dev/null
  sed -i "/^$uname|/d" "$SSH_DB"
  echo -e "${GREEN}Account deleted${NC}"; pause
}

lock_unlock_ssh(){
  banner; echo -e "${BOLD}--- Lock / Unlock SSH Account ---${NC}"
  read -rp " Username: " uname
  if ! id "$uname" &>/dev/null; then echo -e "${RED}Not found${NC}"; pause; return; fi
  echo " 1) Lock account"; echo " 2) Unlock account"
  read -rp " Choose: " a
  if [ "$a" == "1" ]; then
    usermod -L "$uname"; sed -i "s/^\($uname|.*|\)[^|]*$/\1locked/" "$SSH_DB"
    echo -e "${YELLOW}Account locked${NC}"
  else
    usermod -U "$uname"; sed -i "s/^\($uname|.*|\)[^|]*$/\1active/" "$SSH_DB"
    echo -e "${GREEN}Account unlocked${NC}"
  fi
  pause
}

ssh_menu(){
while true; do
banner
echo -e "${BOLD} SSH Account Management${NC}"
echo " 1) Create new account"
echo " 2) List all accounts"
echo " 3) Delete account"
echo " 4) Lock / Unlock account"
echo " 0) Back"
read -rp " Choose: " c
case $c in
  1) create_ssh_account ;;
  2) list_ssh_accounts ;;
  3) delete_ssh_account ;;
  4) lock_unlock_ssh ;;
  0) return ;;
esac
done
}

# ---------------- Xray (vmess/vless/trojan) ----------------
create_xray_account(){
  proto=$1
  case $proto in
    vmess) tag="vmess-ws"; db="$VMESS_DB"; localport=4431 ;;
    vless) tag="vless-ws"; db="$VLESS_DB"; localport=4432 ;;
    trojan) tag="trojan-ws"; db="$TROJAN_DB"; localport=4433 ;;
  esac
  banner; echo -e "${BOLD}--- Create New $proto Account ---${NC}"
  read -rp " Account name (email/label): " name
  [ -z "$name" ] && { echo -e "${RED}Invalid name${NC}"; pause; return; }
  ask_limits

  if [ "$proto" == "trojan" ]; then
    cred=$(openssl rand -hex 8)
    client=$(jq -n --arg pass "$cred" --arg email "$name" '{password:$pass, email:$email, level:0}')
  else
    cred=$(cat /proc/sys/kernel/random/uuid)
    if [ "$proto" == "vmess" ]; then
      client=$(jq -n --arg id "$cred" --arg email "$name" '{id:$id, alterId:0, email:$email, level:0}')
    else
      client=$(jq -n --arg id "$cred" --arg email "$name" '{id:$id, email:$email, level:0}')
    fi
  fi

  tmp=$(mktemp)
  jq --arg tag "$tag" --argjson c "$client" \
    '(.inbounds[] | select(.tag==$tag) | .settings.clients) += [$c]' \
    "$XRAY_CONFIG" > "$tmp"
  if ! apply_xray_config "$tmp"; then pause; return; fi

  expiry="-"
  [ "$DAYS" != "0" ] && expiry=$(date -d "+$DAYS days" +%Y-%m-%d)
  echo "$name|$cred|$TYPE|$MAXCONN|$QUOTA|$expiry|$(date +%Y-%m-%d)|active" >> "$db"

  print_account_links "$proto" "$name" "$cred"
  [ "$TYPE" == "limited" ] && echo " Limits   : Conn(info)=$MAXCONN | Quota=${QUOTA}GB | Expiry=$expiry"
  pause
}

# Build and print ready-to-import connection links (TLS on 443 + NoTLS on 80)
print_account_links(){
  proto=$1; name=$2; cred=$3
  line="════════════════════════════════════════════════════════════"

  case $proto in
    vless)
      link_tls="vless://${cred}@${DOMAIN}:443?path=/vless&security=tls&encryption=none&host=${DOMAIN}&type=ws&sni=${DOMAIN}#${name}"
      link_notls="vless://${cred}@${DOMAIN}:80?path=/vless&security=none&encryption=none&host=${DOMAIN}&type=ws#${name}"
      ;;
    trojan)
      link_tls="trojan://${cred}@${DOMAIN}:443?path=/trojan&security=tls&host=${DOMAIN}&type=ws&sni=${DOMAIN}#${name}"
      link_notls="trojan://${cred}@${DOMAIN}:80?path=/trojan&security=none&host=${DOMAIN}&type=ws#${name}"
      ;;
    vmess)
      json_tls=$(jq -nc --arg ps "$name" --arg add "$DOMAIN" --arg id "$cred" --arg host "$DOMAIN" \
        '{v:"2",ps:$ps,add:$add,port:"443",id:$id,aid:"0",net:"ws",type:"none",host:$host,path:"/vmess",tls:"tls",sni:$host}')
      json_notls=$(jq -nc --arg ps "$name" --arg add "$DOMAIN" --arg id "$cred" --arg host "$DOMAIN" \
        '{v:"2",ps:$ps,add:$add,port:"80",id:$id,aid:"0",net:"ws",type:"none",host:$host,path:"/vmess",tls:""}')
      link_tls="vmess://$(echo -n "$json_tls" | base64 -w0)"
      link_notls="vmess://$(echo -n "$json_notls" | base64 -w0)"
      ;;
  esac

  banner
  echo -e "${GREEN}${BOLD}$proto account created successfully ✅${NC}"
  echo " Name     : $name"
  if [ "$proto" == "trojan" ]; then echo " Password : $cred"; else echo " UUID     : $cred"; fi
  echo " Domain   : $DOMAIN"
  echo ""
  echo -e "${CYAN}$line${NC}"
  echo " WS TLS 443     :"
  echo "$link_tls"
  echo -e "${CYAN}$line${NC}"
  echo " WS NoTLS 80    :"
  echo "$link_notls"
  echo -e "${CYAN}$line${NC}"
}

list_xray_accounts(){
  proto=$1
  case $proto in
    vmess) db="$VMESS_DB" ;; vless) db="$VLESS_DB" ;; trojan) db="$TROJAN_DB" ;;
  esac
  banner; echo -e "${BOLD}--- $proto Accounts List ---${NC}"
  printf "%-18s %-10s %-6s %-12s %-10s\n" "Name" "Type" "GB" "Expiry" "Status"
  echo "----------------------------------------------------------------------"
  [ -s "$db" ] && while IFS='|' read -r n cr t m q e c s; do
    [ -z "$n" ] && continue
    printf "%-18s %-10s %-6s %-12s %-10s\n" "$n" "$t" "$q" "$e" "$s"
  done < "$db"
  echo ""
  echo " Tip: use 'Show links' to re-print the import links for an existing account."
  pause
}

show_links_menu(){
  proto=$1
  case $proto in
    vmess) db="$VMESS_DB" ;; vless) db="$VLESS_DB" ;; trojan) db="$TROJAN_DB" ;;
  esac
  banner; echo -e "${BOLD}--- Show Links for an Existing $proto Account ---${NC}"
  read -rp " Account name: " name
  cred=$(awk -F'|' -v n="$name" '$1==n{print $2; exit}' "$db")
  if [ -z "$cred" ]; then echo -e "${RED}Not found${NC}"; pause; return; fi
  print_account_links "$proto" "$name" "$cred"
  pause
}

delete_xray_account(){
  proto=$1
  case $proto in
    vmess) tag="vmess-ws"; db="$VMESS_DB" ;;
    vless) tag="vless-ws"; db="$VLESS_DB" ;;
    trojan) tag="trojan-ws"; db="$TROJAN_DB" ;;
  esac
  banner; echo -e "${BOLD}--- Delete $proto Account ---${NC}"
  read -rp " Account name: " name
  cred=$(awk -F'|' -v n="$name" '$1==n{print $2; exit}' "$db")
  if [ -z "$cred" ]; then echo -e "${RED}Not found${NC}"; pause; return; fi
  tmp=$(mktemp)
  jq --arg tag "$tag" --arg id "$cred" \
    '(.inbounds[] | select(.tag==$tag) | .settings.clients) |= map(select((.id // "") != $id and (.password // "") != $id))' \
    "$XRAY_CONFIG" > "$tmp"
  apply_xray_config "$tmp"
  sed -i "/^$name|/d" "$db"
  echo -e "${GREEN}Account deleted${NC}"; pause
}

xray_menu(){
proto=$1
while true; do
banner
echo -e "${BOLD} $proto Account Management${NC}"
echo " 1) Create new account"
echo " 2) List all accounts"
echo " 3) Delete account"
echo " 4) Show import links for an existing account"
echo " 0) Back"
read -rp " Choose: " c
case $c in
  1) create_xray_account "$proto" ;;
  2) list_xray_accounts "$proto" ;;
  3) delete_xray_account "$proto" ;;
  4) show_links_menu "$proto" ;;
  0) return ;;
esac
done
}

# ---------------- Live monitor ----------------
live_online(){
  echo -e "${YELLOW}Press q then Enter to exit live mode${NC}"; sleep 1
  while true; do
    banner
    echo -e "${BOLD} Online Now (refreshes every 2 seconds)${NC}"
    echo " Total active SSH connections : $(online_ssh_count)"
    echo ""
    ss -tn state established 2>/dev/null | awk '{print $4}' | grep -E ':(22|442|8080)$' | sort | uniq -c | sort -rn | head -n 15
    read -t 2 -n 1 key
    [ "$key" == "q" ] && break
  done
}

# ---------------- Usage monitor ----------------
usage_menu(){
  banner; echo -e "${BOLD}--- Quota Usage Monitor ---${NC}"
  echo -e "${CYAN}[SSH]${NC}"
  printf "%-15s %-10s\n" "Username" "Used(GB)"
  [ -s "$SSH_DB" ] && while IFS='|' read -r u t m q e c s; do
    [ -z "$u" ] && continue
    used=$(iptables -L "br_$u" -v -x -n 2>/dev/null | awk '/RETURN/{printf "%.2f", $2/1073741824; exit}')
    [ -z "$used" ] && used="0.00"
    printf "%-15s %-10s\n" "$u" "$used"
  done < "$SSH_DB"
  echo ""
  echo -e "${CYAN}[Vmess/Vless/Trojan]${NC}"
  printf "%-18s %-10s\n" "Name" "Used(GB)"
  for proto in vmess vless trojan; do
    db="$DB/$proto.db"
    [ -s "$db" ] && while IFS='|' read -r n cr t m q e c s; do
      [ -z "$n" ] && continue
      stat=$(xray api statsquery --server=127.0.0.1:10085 -pattern "user>>>$n>>>traffic" 2>/dev/null)
      total=$(echo "$stat" | jq '([.stat[]?.value] | add // 0) / 1073741824' 2>/dev/null)
      [ -z "$total" ] && total="0"
      printf "%-18s %-10s\n" "$n" "$total"
    done < "$db"
  done
  pause
}

# ---------------- Services ----------------
SERVICES="ssh nginx haproxy stunnel4 xray cron"
services_menu(){
while true; do
banner
echo -e "${BOLD} Services Status${NC}"
i=1
declare -A idx_map
for s in $SERVICES; do
  st=$(systemctl is-active "$s" 2>/dev/null)
  if [ "$st" == "active" ]; then col="${GREEN}"; else col="${RED}"; fi
  printf " %d) %-12s : ${col}%s${NC}\n" "$i" "$s" "$st"
  idx_map[$i]=$s
  i=$((i+1))
done
badcount=$(systemctl list-units --type=service --all 2>/dev/null | grep -c 'badvpn-udpgw@.*active')
echo " ${i}) badvpn-udpgw (active on: $badcount ports)"
echo ""
echo " r) Restart ALL services"
echo " 0) Back"
read -rp " Enter service number to restart, or r, or 0: " c
if [ "$c" == "0" ]; then return; fi
if [ "$c" == "r" ]; then
  for s in $SERVICES; do systemctl restart "$s"; done
  for p in 7100 7200 7300 7400 7500 7600 7700 7800 7900; do systemctl restart "badvpn-udpgw@$p" 2>/dev/null; done
  echo -e "${GREEN}All services restarted${NC}"; pause
elif [ -n "${idx_map[$c]}" ]; then
  systemctl restart "${idx_map[$c]}"
  echo -e "${GREEN}${idx_map[$c]} restarted${NC}"; pause
fi
done
}

clear_cache(){
  banner; echo -e "${BOLD}--- Clear Cache ---${NC}"
  apt-get clean -y >/dev/null 2>&1
  apt-get autoremove -y >/dev/null 2>&1
  journalctl --vacuum-time=3d >/dev/null 2>&1
  : > /var/log/xray/access.log 2>/dev/null
  echo -e "${GREEN}Cache and system logs cleared${NC}"
  pause
}

main_menu(){
while true; do
banner
echo -e "${BOLD} Main Menu${NC}"
echo " 1)  SSH accounts management"
echo " 2)  Vmess accounts management"
echo " 3)  Vless accounts management"
echo " 4)  Trojan accounts management"
echo " 5)  Online now (live)"
echo " 6)  Quota usage monitor (GB)"
echo " 7)  Services status / restart"
echo " 8)  Clear cache"
echo " 9)  Show full server report"
echo " 0)  Exit"
echo -e "${CYAN}=====================================================================${NC}"
read -rp " Choose: " c
case $c in
  1) ssh_menu ;;
  2) xray_menu vmess ;;
  3) xray_menu vless ;;
  4) xray_menu trojan ;;
  5) live_online ;;
  6) usage_menu ;;
  7) services_menu ;;
  8) clear_cache ;;
  9) banner; cat "$INFO_FILE" 2>/dev/null; pause ;;
  0) exit 0 ;;
  *) ;;
esac
done
}

main_menu
MENUEOF
chmod +x /usr/local/bin/byteroot
ln -sf /usr/local/bin/byteroot /usr/local/bin/menu

# ---------------------------------------------------------------
# 13) Auto-renew cert cronjob
# ---------------------------------------------------------------
( crontab -l 2>/dev/null | grep -v 'certbot renew' ; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx; systemctl restart stunnel4 xray haproxy'" ) | crontab -

# ---------------------------------------------------------------
# 14) Final report
# ---------------------------------------------------------------
{
echo ""
echo "----------------- General -----------------"
echo "OpenSSH              : 22"
echo "SSH Websocket         : 80 , 8080  (default path on 80, direct on 8080)"
echo "SSH Stunnel SSL/TLS   : 442 (direct)  AND  443 (shared via HAProxy)"
echo "Badvpn UDPGW          : 7100-7900"
echo "Nginx                 : 81"
echo "Vmess WS TLS          : 443  path /vmess   (SNI must = $DOMAIN)"
echo "Vless WS TLS          : 443  path /vless   (SNI must = $DOMAIN)"
echo "Trojan WS TLS         : 443  path /trojan  (SNI must = $DOMAIN)"
echo "Vmess WS NoTLS        : 80   path /vmess"
echo "Vless WS NoTLS        : 80   path /vless"
echo "Trojan WS NoTLS       : 80   path /trojan"
echo "============================================="
echo "NOTE: Port 443 is shared between Stunnel(SSH-SSL) and Nginx(Vmess/Vless/Trojan)"
echo "      via HAProxy, which routes by TLS SNI:"
echo "        - SNI = $DOMAIN            -> Nginx (Vmess/Vless/Trojan TLS)"
echo "        - No SNI / different SNI   -> Stunnel (SSH-SSL)"
echo "      In your SSH-SSL client (HTTP Injector/KPN/etc.) leave SNI/SAN empty"
echo "      or set it to anything other than $DOMAIN."
echo "============================================="
echo "Dev. Eng Abdelrahman Rabie | Telegram: @PacketBreaker - ByteRoot VPN"
} >> "$INFO_FILE"

banner
echo -e "${GREEN}[✓] All services installed and running successfully!${NC}"
echo ""
cat "$INFO_FILE"
echo ""
echo -e "${YELLOW}Full report saved to: $INFO_FILE${NC}"
echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN}      ByteRoot VPN - Dev. Eng Abdelrahman Rabie | Telegram: @PacketBreaker${NC}"
echo -e "${CYAN}=====================================================${NC}"
echo -e "${GREEN}Type 'byteroot' anytime to open the management panel.${NC}"
sleep 2
/usr/local/bin/byteroot
