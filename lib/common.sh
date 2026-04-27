#!/bin/bash
# lib/common.sh — общие функции для всех скриптов vpn-split.
# Source это в начале каждого скрипта: . /usr/local/lib/vpn-split/common.sh

VPN_SPLIT_CONFIG="${VPN_SPLIT_CONFIG:-/etc/vpn-split/config.env}"

# Загружает /etc/vpn-split/config.env. Падает с понятной ошибкой, если файла нет.
# Экспортирует все переменные, чтобы дочерние процессы (awk, dnsmasq) их видели.
load_config() {
    if [[ ! -f "$VPN_SPLIT_CONFIG" ]]; then
        echo "ERROR: $VPN_SPLIT_CONFIG не найден. Запустите install.sh." >&2
        return 1
    fi
    set -a
    # shellcheck disable=SC1090
    . "$VPN_SPLIT_CONFIG"
    set +a

    : "${WAN_IF:?WAN_IF не задан в $VPN_SPLIT_CONFIG}"
    : "${LAN_IF:?LAN_IF не задан в $VPN_SPLIT_CONFIG}"
    : "${VPN_IF:?VPN_IF не задан в $VPN_SPLIT_CONFIG}"
    : "${LAN_NET:?LAN_NET не задан в $VPN_SPLIT_CONFIG}"
    : "${LAN_IP:?LAN_IP не задан в $VPN_SPLIT_CONFIG}"
}

# Возвращает текущий default gateway (через $WAN_IF, если задан, иначе любой).
# Используется для bypass-таблицы, которую нужно держать в актуальном состоянии
# при смене провайдера/перезагрузке роутера.
get_wan_gw() {
    local wan_if="${1:-${WAN_IF:-}}"
    if [[ -n "$wan_if" ]]; then
        ip route show default dev "$wan_if" 2>/dev/null | awk '/^default/ {print $3; exit}'
    else
        ip route show default 2>/dev/null | awk '/^default/ {print $3; exit}'
    fi
}

# Логгеры, единые по всему проекту.
log()  { echo "[$(date '+%F %T')] $*"; }
warn() { echo "[$(date '+%F %T')] WARN: $*" >&2; }
err()  { echo "[$(date '+%F %T')] ERROR: $*" >&2; }
