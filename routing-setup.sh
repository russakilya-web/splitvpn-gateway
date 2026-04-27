#!/bin/bash
#
# Routing Setup Script
# Настраивает policy-based routing для трёх зон.
#
# Все сетевые параметры берутся из /etc/vpn-split/config.env через lib/common.sh.

set -e

LIB_DIR="${VPN_SPLIT_LIB:-/usr/local/lib/vpn-split}"
# shellcheck disable=SC1091
. "${LIB_DIR}/common.sh"
# shellcheck disable=SC1091
. "${LIB_DIR}/netcalc.sh"
load_config

WAN_GW="$(get_wan_gw "$WAN_IF")"
LAN_PREFIX="$(net_prefix24 "$LAN_NET")"

# Удаляем правила пользователя в диапазоне priority 10-99 (наши зональные).
# Старые остатки не должны конфликтовать с новыми после смены LAN_NET.
cleanup_rules() {
    echo "[*] Очистка старых ip rules (priority 10-99)..."
    local prio
    for prio in $(ip rule show | grep -E "^[1-9][0-9]?:" | cut -d: -f1); do
        ip rule del priority "$prio" 2>/dev/null || true
    done
}

setup_vpn_zone() {
    echo "[*] Настройка VPN зоны (${LAN_PREFIX}.20-30)..."
    local i
    for i in $(seq 20 30); do
        ip rule add from "${LAN_PREFIX}.${i}" lookup vpn priority 10 2>/dev/null || true
    done
}

setup_bypass_zone() {
    echo "[*] Настройка Bypass зоны (${LAN_PREFIX}.31-49)..."
    local i
    for i in $(seq 31 49); do
        ip rule add from "${LAN_PREFIX}.${i}" lookup bypass priority 20 2>/dev/null || true
    done
}

setup_split_zone() {
    echo "[*] Настройка Split зоны..."
    ip rule add fwmark 0x1 lookup vpn priority 30 2>/dev/null || true
    ipset create vpn_domains hash:ip timeout 86400 2>/dev/null || ipset flush vpn_domains
}

setup_routes() {
    echo "[*] Настройка маршрутов..."
    if ip link show "$VPN_IF" &>/dev/null; then
        ip route replace default dev "$VPN_IF" table vpn 2>/dev/null || true
        echo "    VPN route: default via $VPN_IF"
    else
        echo "    [!] VPN-интерфейс $VPN_IF не найден — пропускаем VPN-маршрут"
    fi

    if [[ -n "$WAN_GW" ]]; then
        ip route replace default via "$WAN_GW" dev "$WAN_IF" table bypass 2>/dev/null || true
        echo "    Bypass route: default via $WAN_GW dev $WAN_IF"
    else
        echo "    [!] Не удалось определить WAN gateway — bypass-таблица не настроена"
    fi
}

setup_bypass_dns_redirect() {
    echo "[*] Настройка DNS-редиректа для Bypass зоны..."
    local EXTERNAL_DNS="8.8.8.8"
    local i client_ip
    for i in $(seq 31 49); do
        client_ip="${LAN_PREFIX}.${i}"
        iptables -t nat -C PREROUTING -s "$client_ip" -p udp --dport 53 -j DNAT --to-destination "${EXTERNAL_DNS}:53" 2>/dev/null || \
            iptables -t nat -A PREROUTING -s "$client_ip" -p udp --dport 53 -j DNAT --to-destination "${EXTERNAL_DNS}:53"
        iptables -t nat -C PREROUTING -s "$client_ip" -p tcp --dport 53 -j DNAT --to-destination "${EXTERNAL_DNS}:53" 2>/dev/null || \
            iptables -t nat -A PREROUTING -s "$client_ip" -p tcp --dport 53 -j DNAT --to-destination "${EXTERNAL_DNS}:53"
    done
    echo "    Bypass DNS-редирект: ${LAN_PREFIX}.31-49 → ${EXTERNAL_DNS}"
}

setup_iptables() {
    echo "[*] Настройка iptables..."
    iptables -t nat -C POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE

    if ip link show "$VPN_IF" &>/dev/null; then
        iptables -t nat -C POSTROUTING -o "$VPN_IF" -j MASQUERADE 2>/dev/null || \
            iptables -t nat -A POSTROUTING -o "$VPN_IF" -j MASQUERADE
    fi

    iptables -C FORWARD -i "$LAN_IF" -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "$LAN_IF" -j ACCEPT
    iptables -C FORWARD -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT

    iptables -t mangle -C PREROUTING -i "$LAN_IF" -m set --match-set vpn_domains dst -j MARK --set-mark 0x1 2>/dev/null || \
        iptables -t mangle -A PREROUTING -i "$LAN_IF" -m set --match-set vpn_domains dst -j MARK --set-mark 0x1

    echo "    iptables настроены"
}

save_iptables() {
    echo "[*] Сохранение iptables..."
    iptables-save > /etc/iptables/rules.v4
}

main() {
    echo "======================================"
    echo "  VPN Gateway Routing Setup"
    echo "  WAN=${WAN_IF}(${WAN_GW:-?})  LAN=${LAN_IF}(${LAN_NET})  VPN=${VPN_IF}"
    echo "======================================"

    cleanup_rules
    setup_vpn_zone
    setup_bypass_zone
    setup_split_zone
    setup_routes
    setup_bypass_dns_redirect
    setup_iptables
    save_iptables

    echo ""
    echo "[✓] Маршрутизация настроена!"
    echo ""
    echo "Текущие правила:"
    ip rule show | head -20
}

main "$@"
