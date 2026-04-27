#!/bin/bash
# vpn-split-enforce.sh
# Применяет/охраняет правила split-routing для трёх зон поверх AmneziaWG.
#
# Запуск:
#   sudo ./vpn-split-enforce.sh           # one-shot apply
#   sudo ./vpn-split-enforce.sh --watch   # daemon: пере-применять при флапе VPN_IF

set -u

LIB_DIR="${VPN_SPLIT_LIB:-/usr/local/lib/vpn-split}"
# shellcheck disable=SC1091
. "${LIB_DIR}/common.sh"
# shellcheck disable=SC1091
. "${LIB_DIR}/netcalc.sh"
load_config

LAN_NET_RAW="$LAN_NET"           # 192.168.1.0/24
LAN_PREFIX="$(net_prefix24 "$LAN_NET_RAW")"

VPN_TABLE="vpn"
VPN_TABLE_ID=100
BYPASS_TABLE="bypass"
BYPASS_TABLE_ID=200
FW_MARK=1
IPSET_NAME="vpn_dst"

VPN_IP_START=20
VPN_IP_END=30

BYPASS_IP_START=31
BYPASS_IP_END=49
EXTERNAL_DNS="8.8.8.8"

IP_LIST="/root/ip-list.txt"
SLEEP_WATCH=3

ensure_vpn_table() {
    grep -qs "^${VPN_TABLE_ID} ${VPN_TABLE}\b" /etc/iproute2/rt_tables \
        || echo "${VPN_TABLE_ID} ${VPN_TABLE}" >> /etc/iproute2/rt_tables
}

ensure_bypass_table() {
    grep -qs "^${BYPASS_TABLE_ID} ${BYPASS_TABLE}\b" /etc/iproute2/rt_tables \
        || echo "${BYPASS_TABLE_ID} ${BYPASS_TABLE}" >> /etc/iproute2/rt_tables
}

ensure_lan() {
    log "Configuring LAN ${LAN_IF} -> ${LAN_IP}"
    dhclient -r "${LAN_IF}" 2>/dev/null || true
    ip addr flush dev "${LAN_IF}" || true
    ip addr add "${LAN_IP}" dev "${LAN_IF}" || true
    ip link set "${LAN_IF}" up
}

ensure_wan() {
    log "Ensuring WAN ${WAN_IF} has IP (dhclient)"
    dhclient -v "${WAN_IF}" 2>/dev/null || true
    local wan_gw; wan_gw="$(get_wan_gw "$WAN_IF")"
    if [[ -n "$wan_gw" ]]; then
        ip route replace default via "$wan_gw" dev "${WAN_IF}"
    else
        warn "Не удалось определить WAN gateway"
    fi
}

ensure_nat_forward() {
    log "Enabling ip_forward and NAT"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    iptables -P FORWARD ACCEPT 2>/dev/null || true

    iptables -t nat -C POSTROUTING -o "${WAN_IF}" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "${WAN_IF}" -j MASQUERADE

    iptables -C FORWARD -i "${LAN_IF}" -o "${WAN_IF}" -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "${LAN_IF}" -o "${WAN_IF}" -j ACCEPT
    iptables -C FORWARD -i "${WAN_IF}" -o "${LAN_IF}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "${WAN_IF}" -o "${LAN_IF}" -m state --state RELATED,ESTABLISHED -j ACCEPT

    if ip link show "${VPN_IF}" >/dev/null 2>&1; then
        iptables -C FORWARD -i "${LAN_IF}" -o "${VPN_IF}" -j ACCEPT 2>/dev/null || \
            iptables -A FORWARD -i "${LAN_IF}" -o "${VPN_IF}" -j ACCEPT
        iptables -C FORWARD -i "${VPN_IF}" -o "${LAN_IF}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
            iptables -A FORWARD -i "${VPN_IF}" -o "${LAN_IF}" -m state --state RELATED,ESTABLISHED -j ACCEPT
    fi
}

ensure_vpn_zone() {
    log "Configuring VPN zone (${LAN_PREFIX}.${VPN_IP_START}-${VPN_IP_END})"
    ensure_vpn_table

    local i client_ip
    for i in $(seq ${VPN_IP_START} ${VPN_IP_END}); do
        client_ip="${LAN_PREFIX}.${i}"
        # Чистим всё, что было раньше (на случай ручных правил), и кладём одно — наше.
        while ip rule del from "${client_ip}" 2>/dev/null; do :; done
        ip rule add from "${client_ip}" lookup "${VPN_TABLE}" priority 10 2>/dev/null || true
    done

    log "VPN zone configured: $((VPN_IP_END - VPN_IP_START + 1)) IPs -> table ${VPN_TABLE} -> ${VPN_IF}"
}

ensure_bypass_zone() {
    log "Configuring bypass zone (${LAN_PREFIX}.${BYPASS_IP_START}-${BYPASS_IP_END})"
    ensure_bypass_table

    local wan_gw; wan_gw="$(get_wan_gw "$WAN_IF")"
    if [[ -n "$wan_gw" ]]; then
        ip route replace default via "$wan_gw" dev "${WAN_IF}" table "${BYPASS_TABLE}" 2>/dev/null || true
    fi

    local i client_ip
    for i in $(seq ${BYPASS_IP_START} ${BYPASS_IP_END}); do
        client_ip="${LAN_PREFIX}.${i}"
        while ip rule del from "${client_ip}" 2>/dev/null; do :; done
        ip rule add from "${client_ip}" lookup "${BYPASS_TABLE}" priority 20 2>/dev/null || true

        iptables -t nat -C PREROUTING -s "${client_ip}" -p udp --dport 53 -j DNAT --to-destination "${EXTERNAL_DNS}:53" 2>/dev/null || \
            iptables -t nat -A PREROUTING -s "${client_ip}" -p udp --dport 53 -j DNAT --to-destination "${EXTERNAL_DNS}:53"
        iptables -t nat -C PREROUTING -s "${client_ip}" -p tcp --dport 53 -j DNAT --to-destination "${EXTERNAL_DNS}:53" 2>/dev/null || \
            iptables -t nat -A PREROUTING -s "${client_ip}" -p tcp --dport 53 -j DNAT --to-destination "${EXTERNAL_DNS}:53"
    done

    log "Bypass zone configured: $((BYPASS_IP_END - BYPASS_IP_START + 1)) IPs -> table ${BYPASS_TABLE} -> ${wan_gw:-?}"
}

ensure_vpn_routing_and_rules() {
    ensure_vpn_table
    ip route flush table "${VPN_TABLE}" 2>/dev/null || true

    if ip link show "${VPN_IF}" >/dev/null 2>&1; then
        ip route replace default dev "${VPN_IF}" table "${VPN_TABLE}" 2>/dev/null || true
    else
        ip route del default table "${VPN_TABLE}" 2>/dev/null || true
    fi

    ip rule del pref 100 fwmark "${FW_MARK}" lookup "${VPN_TABLE}" 2>/dev/null || true
    ip rule del fwmark "${FW_MARK}" table "${VPN_TABLE}" 2>/dev/null || true

    ip rule add pref 100 fwmark "${FW_MARK}" lookup "${VPN_TABLE}"
    ip rule add pref 110 lookup main suppress_prefixlength 0 2>/dev/null || true

    log "ip rules:"
    ip rule show
    log "vpn table:"
    ip route show table "${VPN_TABLE}" || true
}

ensure_ipset() {
    log "Creating ipset ${IPSET_NAME} from ${IP_LIST}"
    ipset destroy "${IPSET_NAME}" 2>/dev/null || true
    ipset create "${IPSET_NAME}" hash:net 2>/dev/null || true

    if [[ ! -f "${IP_LIST}" ]]; then
        log "WARNING: ip-list file not found: ${IP_LIST}, skipping seed"
    else
        local net
        while IFS= read -r net || [[ -n "$net" ]]; do
            net="${net%%#*}"
            net="${net//[[:space:]]/}"
            [[ -z "$net" ]] && continue
            ipset add "${IPSET_NAME}" "${net}" 2>/dev/null || true
        done < "${IP_LIST}"
    fi

    ipset create vpn_domains hash:ip timeout 86400 2>/dev/null || true
    log "Ensured ipset vpn_domains exists"
}

ensure_marking() {
    local set_name
    for set_name in "${IPSET_NAME}" vpn_domains; do
        log "Configuring mangle rule: from ${LAN_NET_RAW} dst ∈ ${set_name} -> mark ${FW_MARK}"
        while iptables -t mangle -D PREROUTING -s "${LAN_NET_RAW}" -m set --match-set "${set_name}" dst -j MARK --set-mark "${FW_MARK}" 2>/dev/null; do :; done
        iptables -t mangle -A PREROUTING -s "${LAN_NET_RAW}" -m set --match-set "${set_name}" dst -j MARK --set-mark "${FW_MARK}"
    done
}

ensure_vpn_nat() {
    if ip link show "${VPN_IF}" >/dev/null 2>&1; then
        iptables -t nat -C POSTROUTING -o "${VPN_IF}" -j MASQUERADE 2>/dev/null || \
            iptables -t nat -A POSTROUTING -o "${VPN_IF}" -j MASQUERADE
    else
        iptables -t nat -D POSTROUTING -o "${VPN_IF}" -j MASQUERADE 2>/dev/null || true
    fi
}

flush_conntrack() {
    if command -v conntrack >/dev/null 2>&1; then
        log "Flushing conntrack table to drop dead VPN sessions"
        conntrack -F 2>/dev/null || true
    fi
}

apply_once() {
    log "Ensure LAN/WAN"
    ensure_lan
    ensure_wan

    log "Ensure NAT/forward"
    ensure_nat_forward

    log "Ensure ipset"
    ensure_ipset

    log "Ensure vpn routing and ip rules"
    ensure_vpn_routing_and_rules

    log "Ensure vpn zone"
    ensure_vpn_zone

    log "Ensure bypass zone"
    ensure_bypass_zone

    log "Ensure marking and vpn-nat"
    ensure_marking
    ensure_vpn_nat

    log "Optional: flush conntrack"
    flush_conntrack

    log "Done apply. Current routes:"
    ip route
    ip rule show
    ipset list "${IPSET_NAME}" 2>/dev/null || true
}

watch_loop() {
    log "Entering watch mode: monitoring ${VPN_IF} (Ctrl-C to stop)"
    local prev_state="" state
    while true; do
        if ip link show "${VPN_IF}" >/dev/null 2>&1; then
            state="up"
        else
            state="down"
        fi

        if [[ "${state}" != "${prev_state}" ]]; then
            log "Detected ${VPN_IF} state change: ${prev_state} -> ${state}"
            apply_once
            prev_state="${state}"
        else
            # Если кто-то снёс наше fwmark-правило — восстановим.
            if ! ip rule show | grep -q "fwmark 0x$(printf '%x' ${FW_MARK}) lookup ${VPN_TABLE}"; then
                log "Reinstalling ip rule for fwmark"
                ip rule del fwmark "${FW_MARK}" table "${VPN_TABLE}" 2>/dev/null || true
                ip rule add pref 100 fwmark "${FW_MARK}" lookup "${VPN_TABLE}" 2>/dev/null || true
            fi
        fi
        sleep "${SLEEP_WATCH}"
    done
}

if [[ "${1:-}" == "--watch" ]]; then
    apply_once
    watch_loop
else
    apply_once
fi

exit 0
