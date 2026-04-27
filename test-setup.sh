#!/bin/bash
#
# test-setup.sh — smoke-проверка установленного splitvpn-gateway.
# Все параметры читаются из /etc/vpn-split/config.env.
#

set -u

LIB_DIR="${VPN_SPLIT_LIB:-/usr/local/lib/vpn-split}"
# shellcheck disable=SC1091
. "${LIB_DIR}/common.sh"
# shellcheck disable=SC1091
. "${LIB_DIR}/netcalc.sh"
load_config

LAN_IP_PLAIN="${LAN_IP%/*}"
LAN_PREFIX="$(net_prefix24 "$LAN_NET")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
TESTS_PASSED=0; TESTS_FAILED=0

pass() { echo -e "${GREEN}[✓]${NC} $1"; ((TESTS_PASSED++)); }
fail() { echo -e "${RED}[✗]${NC} $1"; ((TESTS_FAILED++)); }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

echo "======================================"
echo "  splitvpn-gateway: configuration test"
echo "  WAN=${WAN_IF}  LAN=${LAN_IF}  VPN=${VPN_IF}"
echo "======================================"
echo ""

echo "1. IP forwarding"
[[ "$(cat /proc/sys/net/ipv4/ip_forward)" == "1" ]] \
    && pass "ip_forward=1" || fail "ip_forward выключен"

echo ""; echo "2. LAN-интерфейс ${LAN_IF}"
ip addr show "$LAN_IF" 2>/dev/null | grep -q "$LAN_IP_PLAIN" \
    && pass "${LAN_IF} имеет ${LAN_IP_PLAIN}" \
    || fail "${LAN_IF} не настроен или без ${LAN_IP_PLAIN}"

echo ""; echo "3. AmneziaWG-интерфейс ${VPN_IF}"
ip link show "$VPN_IF" &>/dev/null \
    && pass "${VPN_IF} существует" \
    || fail "${VPN_IF} не найден (проверьте 'systemctl status awg-quick@${VPN_IF}')"

echo ""; echo "4. Таблицы маршрутизации"
grep -q "^100 vpn$"    /etc/iproute2/rt_tables && pass "table vpn" || fail "table vpn нет"
grep -q "^200 bypass$" /etc/iproute2/rt_tables && pass "table bypass" || fail "table bypass нет"

echo ""; echo "5. ip rules"
vpn_rules=$(ip rule show | grep -c "lookup vpn" || echo 0)
[[ "$vpn_rules" -gt 0 ]] && pass "VPN rules: $vpn_rules" || fail "VPN rules не настроены"
bypass_rules=$(ip rule show | grep -c "lookup bypass" || echo 0)
[[ "$bypass_rules" -gt 0 ]] && pass "Bypass rules: $bypass_rules" || warn "Bypass rules: 0"

echo ""; echo "6. ipset"
if ipset list vpn_domains &>/dev/null; then
    ip_count=$(ipset list vpn_domains | grep -c "^[0-9]" || echo 0)
    pass "ipset vpn_domains: $ip_count IP"
else
    fail "ipset vpn_domains не создан"
fi

echo ""; echo "7. systemd-сервисы"
for svc in "awg-quick@${VPN_IF}" isc-dhcp-server dnsmasq iplist-web vpn-gateway-watchdog; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        pass "$svc активен"
    else
        fail "$svc не активен"
    fi
done

echo ""; echo "8. Порты"
ss -tulpn | grep -q ":8080" && pass "web-UI слушает :8080" || fail "порт 8080 не открыт"
ss -tulpn | grep -q ":53"   && pass "dnsmasq слушает :53" || fail "порт 53 не открыт"
ss -tulpn | grep -q ":67"   && pass "dhcpd слушает :67"   || fail "порт 67 не открыт"

echo ""; echo "9. NAT"
iptables -t nat -L POSTROUTING -n | grep -q "MASQUERADE" \
    && pass "MASQUERADE настроен" || fail "MASQUERADE не настроен"

echo ""; echo "10. Bypass DNS DNAT"
iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "${LAN_PREFIX}.31.*8.8.8.8" \
    && pass "DNS DNAT для bypass настроен" || warn "DNS DNAT не виден"

echo ""; echo "11. Списки"
[[ -f /opt/vpn-gateway/vpn-domains.txt ]] && pass "vpn-domains.txt есть" || warn "vpn-domains.txt отсутствует"
[[ -f /opt/vpn-gateway/geohide-hosts.txt ]] && pass "geohide-hosts.txt есть" || warn "geohide-hosts.txt отсутствует"
crontab -l 2>/dev/null | grep -q update-geohide \
    && pass "cron-задача update-geohide настроена" || warn "cron не настроен"

echo ""
echo "======================================"
echo -e "${GREEN}Пройдено:${NC} $TESTS_PASSED   ${RED}Провалено:${NC} $TESTS_FAILED"
echo "======================================"
[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
