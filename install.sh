#!/bin/bash
set -e

INSTALL_DIR="/opt/mikrov2ray"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== MikroV2ray Installer ==="
echo ""

# Check root
if [ "$EUID" -ne 0 ]; then
  echo "Run as root: sudo $0"
  exit 1
fi

# Check Docker
if ! command -v docker &>/dev/null; then
  echo "Docker not found. Installing..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi

# Create install dir and data
mkdir -p "$INSTALL_DIR/data"

# Copy docker-compose
if [ "$SCRIPT_DIR" != "$INSTALL_DIR" ]; then
  cp "$SCRIPT_DIR/docker-compose.yml" "$INSTALL_DIR/"
fi

# Create .env if not exists
if [ ! -f "$INSTALL_DIR/.env" ]; then
  SESSION_SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32)
  cat > "$INSTALL_DIR/.env" <<EOF
LISTEN=:8080
DB_PATH=./data/mikrov2ray.db
SESSION_SECRET=$SESSION_SECRET

MIHOMO_CONTAINER=mihomo
MIHOMO_CONFIG_PATH=./data/mihomo-config.yaml
MIHOMO_API=127.0.0.1:9090

MIKROTIK_ADDRESS=192.168.88.1:8728
MIKROTIK_USERNAME=admin
MIKROTIK_PASSWORD=
EOF
  echo "Created $INSTALL_DIR/.env (edit MikroTik settings later)"
else
  echo ".env already exists, skipping"
fi

# Create empty mihomo config if not exists
if [ ! -f "$INSTALL_DIR/data/mihomo-config.yaml" ]; then
  cat > "$INSTALL_DIR/data/mihomo-config.yaml" <<'YAML'
mixed-port: 1080
tproxy-port: 12345
allow-lan: true
mode: rule
log-level: warning
external-controller: 0.0.0.0:9090
rules:
  - MATCH,DIRECT
YAML
  echo "Created default mihomo config (configure via web panel)"
fi

# Pull and start containers
cd "$INSTALL_DIR"
docker compose pull
docker compose up -d

# --- tproxy setup ---

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-mikrov2ray.conf

# Clean up old iptables rules if exist
iptables -t mangle -D PREROUTING -j MIHOMO 2>/dev/null || true
iptables -t mangle -F MIHOMO 2>/dev/null || true
iptables -t mangle -X MIHOMO 2>/dev/null || true
# Also clean up legacy XRAY chain if upgrading
iptables -t mangle -D PREROUTING -j XRAY 2>/dev/null || true
iptables -t mangle -F XRAY 2>/dev/null || true
iptables -t mangle -X XRAY 2>/dev/null || true

# Create MIHOMO chain
iptables -t mangle -N MIHOMO

# Skip local/private traffic
iptables -t mangle -A MIHOMO -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A MIHOMO -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A MIHOMO -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A MIHOMO -d 192.168.0.0/16 -j RETURN

# Skip mihomo's own outbound traffic (routing-mark 255)
iptables -t mangle -A MIHOMO -m mark --mark 255 -j RETURN

# TPROXY all TCP/UDP to mihomo port 12345
iptables -t mangle -A MIHOMO -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1
iptables -t mangle -A MIHOMO -p udp -j TPROXY --on-port 12345 --tproxy-mark 1

# Apply to forwarded traffic (from MikroTik)
iptables -t mangle -A PREROUTING -j MIHOMO

# Policy routing for tproxy
ip rule del fwmark 1 table 100 2>/dev/null || true
ip rule add fwmark 1 table 100
ip route replace local default dev lo table 100

# Make tproxy persistent across reboots
TPROXY_SCRIPT="$INSTALL_DIR/tproxy-setup.sh"
cat > "$TPROXY_SCRIPT" <<'TEOF'
#!/bin/bash
set -e
sysctl -w net.ipv4.ip_forward=1
iptables -t mangle -D PREROUTING -j MIHOMO 2>/dev/null || true
iptables -t mangle -F MIHOMO 2>/dev/null || true
iptables -t mangle -X MIHOMO 2>/dev/null || true
iptables -t mangle -N MIHOMO
iptables -t mangle -A MIHOMO -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A MIHOMO -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A MIHOMO -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A MIHOMO -d 192.168.0.0/16 -j RETURN
iptables -t mangle -A MIHOMO -m mark --mark 255 -j RETURN
iptables -t mangle -A MIHOMO -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1
iptables -t mangle -A MIHOMO -p udp -j TPROXY --on-port 12345 --tproxy-mark 1
iptables -t mangle -A PREROUTING -j MIHOMO
ip rule del fwmark 1 table 100 2>/dev/null || true
ip rule add fwmark 1 table 100
ip route replace local default dev lo table 100
TEOF
chmod +x "$TPROXY_SCRIPT"

cat > /etc/systemd/system/mikrov2ray-tproxy.service <<EOF
[Unit]
Description=MikroV2ray tproxy iptables rules
After=network.target

[Service]
Type=oneshot
ExecStart=$TPROXY_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable mikrov2ray-tproxy

echo ""
echo "=== Installation complete ==="
echo ""
echo "  Web panel:  http://$(hostname -I | awk '{print $1}'):8080"
echo "  Login:      admin / admin (change after first login)"
echo ""
echo "  Next steps:"
echo "  1. Open web panel, import VLESS URI or fill settings, click Apply & Restart"
echo "  2. Add domains on the Domains tab (auto-synced to MikroTik DNS static)"
echo "  3. On MikroTik tab, click 'Setup Routing' with this host's IP as gateway"
echo ""
