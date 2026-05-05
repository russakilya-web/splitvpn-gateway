#!/bin/bash
#
# VPN Gateway Setup Script
# Конфигурирует Ubuntu в split-VPN-шлюз поверх AmneziaWG.
#
# Этот скрипт обычно запускается из install.sh, но допускает и ручной запуск,
# при условии что /etc/vpn-split/config.env уже создан.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="/var/log/vpn-gateway-setup.log"
LIB_DIR="/usr/local/lib/vpn-split"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Загружаем общие библиотеки и конфиг (WAN_IF/LAN_IF/VPN_IF/LAN_NET/LAN_IP)
# shellcheck disable=SC1091
. "${LIB_DIR}/common.sh"
# shellcheck disable=SC1091
. "${LIB_DIR}/netcalc.sh"
load_config

# Локальные обёртки для совместимости с прежним стилем вывода
log_msg()  { echo -e "${GREEN}[+]${NC} $1"; echo "[$(date '+%F %T')] $1" >> "$LOG"; }
warn_msg() { echo -e "${YELLOW}[!]${NC} $1"; echo "[$(date '+%F %T')] WARN: $1" >> "$LOG"; }
err_msg()  { echo -e "${RED}[!]${NC} $1"; echo "[$(date '+%F %T')] ERROR: $1" >> "$LOG"; exit 1; }

check_root() {
    [[ $EUID -eq 0 ]] || err_msg "Этот скрипт должен быть запущен от root"
}

backup_configs() {
    log_msg "Создание резервных копий..."
    BACKUP_DIR="/root/vpn-gateway-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"

    cp /etc/dhcp/dhcpd.conf "$BACKUP_DIR/" 2>/dev/null || true
    cp /etc/iproute2/rt_tables "$BACKUP_DIR/" 2>/dev/null || true
    cp -r /etc/netplan "$BACKUP_DIR/" 2>/dev/null || true

    ip rule show > "$BACKUP_DIR/ip-rules.txt"
    ip route show > "$BACKUP_DIR/ip-routes.txt"
    iptables-save > "$BACKUP_DIR/iptables.txt"

    log_msg "Резервные копии сохранены в $BACKUP_DIR"
}

install_dependencies() {
    log_msg "Проверка зависимостей (основная установка — в install.sh)..."
    # install.sh уже поставил всё. Здесь — fallback на случай ручного запуска.
    if ! command -v awg-quick >/dev/null; then
        warn_msg "awg-quick не найден — пытаюсь доустановить из ppa:amnezia/ppa"
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -qq software-properties-common
        add-apt-repository -y ppa:amnezia/ppa || true
        apt-get update -qq
        apt-get install -y -qq amneziawg amneziawg-tools
    fi
    apt-get install -y -qq dnsmasq ipset iptables-persistent python3-flask isc-dhcp-server qrencode

    systemctl stop dnsmasq 2>/dev/null || true
    systemctl disable dnsmasq 2>/dev/null || true
}

setup_network() {
    log_msg "Настройка сетевых интерфейсов (LAN: ${LAN_IF} -> ${LAN_IP})..."

    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-vpn-gateway.conf
    sysctl -p /etc/sysctl.d/99-vpn-gateway.conf

    # netplan для LAN: статический IP. WAN управляется DHCP — не трогаем.
    cat > /etc/netplan/99-vpn-gateway.yaml <<EOF
network:
  version: 2
  ethernets:
    ${LAN_IF}:
      addresses:
        - ${LAN_IP}
      dhcp4: false
EOF
    chmod 600 /etc/netplan/99-vpn-gateway.yaml

    log_msg "Применение сетевой конфигурации..."
    netplan apply || warn_msg "netplan apply не удался — возможно ${LAN_IF} не подключён"

    # Ждём, пока интерфейс реально получит IP (netplan apply асинхронный).
    # Без этого setup_dhcp() стартует isc-dhcp-server раньше времени, и тот
    # падает с "Not configured to listen on any interfaces".
    local lan_ip_plain="${LAN_IP%/*}"
    local i
    for i in $(seq 1 30); do
        if ip -4 -o addr show dev "$LAN_IF" 2>/dev/null | grep -qF "$lan_ip_plain"; then
            log_msg "${LAN_IF} получил $lan_ip_plain (через ${i}s)"
            return 0
        fi
        sleep 1
    done
    warn_msg "${LAN_IF} не получил $lan_ip_plain за 30s — DHCP-сервер может упасть"
}

setup_routing_tables() {
    log_msg "Настройка таблиц маршрутизации..."
    # На Ubuntu 26.04+ пакет iproute2 больше не создаёт /etc/iproute2/rt_tables
    # автоматически — создаём сами, чтобы grep/echo не упали.
    mkdir -p /etc/iproute2
    [[ -f /etc/iproute2/rt_tables ]] || touch /etc/iproute2/rt_tables
    grep -q "^100 vpn$"    /etc/iproute2/rt_tables || echo "100 vpn"    >> /etc/iproute2/rt_tables
    grep -q "^200 bypass$" /etc/iproute2/rt_tables || echo "200 bypass" >> /etc/iproute2/rt_tables
}

copy_scripts() {
    log_msg "Копирование скриптов..."

    cp "$SCRIPT_DIR/routing-setup.sh"      /usr/local/sbin/
    cp "$SCRIPT_DIR/vpn-split-enforce.sh"  /usr/local/sbin/
    cp "$SCRIPT_DIR/iplist-web-domains.py" /usr/local/sbin/iplist-web.py
    cp "$SCRIPT_DIR/update-domains.sh"     /usr/local/sbin/
    cp "$SCRIPT_DIR/update-geohide.sh"     /usr/local/sbin/

    chmod +x /usr/local/sbin/routing-setup.sh \
             /usr/local/sbin/vpn-split-enforce.sh \
             /usr/local/sbin/iplist-web.py \
             /usr/local/sbin/update-domains.sh \
             /usr/local/sbin/update-geohide.sh

    mkdir -p /opt/vpn-gateway
    touch /opt/vpn-gateway/vpn-domains.txt
}

setup_dhcp() {
    log_msg "Настройка DHCP (subnet: ${LAN_NET})..."
    local prefix gw bcast
    prefix=$(net_prefix24 "$LAN_NET")
    gw=$(net_gateway24 "$LAN_NET")
    bcast=$(net_broadcast24 "$LAN_NET")

    cat > /etc/dhcp/dhcpd.conf <<EOF
# VPN Gateway DHCP Configuration (auto-generated)
default-lease-time 600;
max-lease-time 7200;
authoritative;

subnet ${prefix}.0 netmask 255.255.255.0 {
    # Динамический пул (Split зона) — ${prefix}.50-199
    range ${prefix}.50 ${prefix}.199;

    option routers ${gw};
    option domain-name-servers ${gw};
    option broadcast-address ${bcast};
}

# ===== VPN ЗОНА (${prefix}.20-30) =====
# Закрепляйте здесь устройства, которые должны идти полностью через VPN.
#
# host my-phone {
#     hardware ethernet AA:BB:CC:DD:EE:FF;
#     fixed-address ${prefix}.20;
# }

# ===== BYPASS ЗОНА (${prefix}.31-49) =====
# Устройства из этой зоны идут напрямую, минуя VPN.
EOF
    # Бинд DHCP-сервера на LAN-интерфейс
    sed -i "s|^INTERFACESv4=.*|INTERFACESv4=\"${LAN_IF}\"|" /etc/default/isc-dhcp-server 2>/dev/null \
        || echo "INTERFACESv4=\"${LAN_IF}\"" >> /etc/default/isc-dhcp-server

    # systemd-override: после netplan/network-online, автоперезапуск при падении.
    # Решает race condition при boot, когда dhcpd стартовал быстрее netplan.
    mkdir -p /etc/systemd/system/isc-dhcp-server.service.d
    cat > /etc/systemd/system/isc-dhcp-server.service.d/override.conf <<'OVR'
[Unit]
After=network-online.target systemd-networkd.service
Wants=network-online.target

[Service]
Restart=on-failure
RestartSec=5
OVR
    systemctl daemon-reload

    systemctl restart isc-dhcp-server
}

setup_dnsmasq() {
    log_msg "Настройка dnsmasq для domain-based routing..."

    mkdir -p /etc/systemd/resolved.conf.d/
    cat > /etc/systemd/resolved.conf.d/no-stub.conf <<'EOF'
[Resolve]
DNSStubListener=no
EOF
    systemctl restart systemd-resolved || true

    cat > /etc/dnsmasq.d/vpn-gateway.conf <<EOF
# VPN Gateway DNS Configuration (auto-generated)
interface=${LAN_IF}
bind-interfaces

server=8.8.8.8
server=8.8.4.4
server=1.1.1.1

cache-size=1000

log-queries
log-facility=/var/log/dnsmasq-queries.log

conf-dir=/etc/dnsmasq.d/domains.d

addn-hosts=/opt/vpn-gateway/geohide-hosts.txt
addn-hosts=/opt/vpn-gateway/custom-hosts.txt
EOF

    mkdir -p /etc/dnsmasq.d/domains.d

    systemctl enable dnsmasq
    systemctl start dnsmasq
}

setup_amneziawg_service() {
    log_msg "Включение awg-quick@${VPN_IF}.service..."
    if [[ ! -f "/etc/amnezia/amneziawg/${VPN_IF}.conf" ]]; then
        warn_msg "Конфиг /etc/amnezia/amneziawg/${VPN_IF}.conf не найден — туннель не запустится"
        return
    fi
    systemctl enable "awg-quick@${VPN_IF}.service" 2>/dev/null || true
    systemctl restart "awg-quick@${VPN_IF}.service" || \
        warn_msg "awg-quick@${VPN_IF} не запустился — проверьте 'journalctl -u awg-quick@${VPN_IF}'"
}

setup_systemd_services() {
    log_msg "Настройка systemd сервисов..."

    systemctl disable vpn-gateway-routing.service 2>/dev/null || true
    systemctl stop    vpn-gateway-routing.service 2>/dev/null || true

    cat > /etc/systemd/system/vpn-gateway-watchdog.service <<EOF
[Unit]
Description=VPN Gateway Watchdog (bypass/split routing enforcer)
After=network-online.target awg-quick@${VPN_IF}.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/vpn-split-enforce.sh --watch
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/iplist-web.service <<'EOF'
[Unit]
Description=VPN Gateway Web Interface
After=network-online.target dnsmasq.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/sbin/iplist-web.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
WorkingDirectory=/opt/vpn-gateway

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable vpn-gateway-watchdog.service
    systemctl enable iplist-web.service
    systemctl restart vpn-gateway-watchdog.service
    systemctl restart iplist-web.service
}

setup_geohide() {
    log_msg "Настройка GeoHide DNS..."
    mkdir -p /opt/vpn-gateway/backups
    touch /opt/vpn-gateway/geohide-hosts.txt

    if [[ ! -f /opt/vpn-gateway/custom-hosts.txt ]]; then
        cat > /opt/vpn-gateway/custom-hosts.txt <<'EOF'
# Custom Hosts File
# Ваши собственные DNS записи для обхода геоблокировки
# Формат: IP DOMAIN
EOF
    fi

    local cron_line="0 4 * * * /usr/local/sbin/update-geohide.sh >> /var/log/vpn-gateway-geohide.log 2>&1"
    (crontab -l 2>/dev/null | grep -v update-geohide; echo "$cron_line") | crontab -

    log_msg "Скачивание GeoHide hosts (можно прервать, если интернета нет)..."
    /usr/local/sbin/update-geohide.sh || warn_msg "Не удалось скачать GeoHide hosts"
}

apply_routing() {
    log_msg "Применение правил маршрутизации..."
    /usr/local/sbin/routing-setup.sh
}

main() {
    echo "======================================"
    echo "  VPN Gateway Setup"
    echo "  WAN=${WAN_IF}  LAN=${LAN_IF}  VPN=${VPN_IF}"
    echo "  LAN=${LAN_NET} ($(net_gateway24 "$LAN_NET"))"
    echo "======================================"
    echo ""

    check_root
    backup_configs
    install_dependencies
    setup_network
    setup_routing_tables
    copy_scripts
    setup_dhcp
    setup_dnsmasq
    setup_amneziawg_service
    setup_geohide
    setup_systemd_services
    apply_routing

    echo ""
    log_msg "Установка завершена!"
    echo ""
    echo "Next steps:"
    echo "  1. Проверьте, что LAN-интерфейс ${LAN_IF} подключён"
    echo "  2. Web-UI: http://${LAN_IP%/*}:8080"
    echo "  3. Добавьте домены для VPN-маршрутизации"
    echo ""
}

main "$@"
