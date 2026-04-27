#!/bin/bash
# lib/netcalc.sh — простые вычисления над CIDR-сетью /24.
# Намеренно поддерживаем только /24 — вся текущая логика зон (.20-.30, .31-.49, .50-.199)
# завязана на 8-битный last-octet.

# 192.168.1.0/24 -> 192.168.1
net_prefix24() {
    local cidr="$1"
    local network="${cidr%/*}"
    echo "${network%.*}"
}

# 192.168.1.0/24 -> 192.168.1.1 (первый usable IP, шлюз)
net_gateway24() {
    local prefix; prefix=$(net_prefix24 "$1")
    echo "${prefix}.1"
}

# 192.168.1.0/24 -> 192.168.1.255 (broadcast)
net_broadcast24() {
    local prefix; prefix=$(net_prefix24 "$1")
    echo "${prefix}.255"
}

# Проверка, что переданный CIDR — /24 (защита от случайного /16 или /23).
net_assert_24() {
    local cidr="$1"
    if [[ "$cidr" != */24 ]]; then
        echo "ERROR: ожидается /24-сеть, получено: $cidr" >&2
        return 1
    fi
}

# Валидация формата CIDR /24 без вывода ошибки (для silent проверок).
net_is_valid_24() {
    local cidr="$1"
    [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/24$ ]] || return 1
    local ip="${cidr%/*}" oct
    IFS='.' read -ra oct <<< "$ip"
    for o in "${oct[@]}"; do
        (( o >= 0 && o <= 255 )) || return 1
    done
    [[ "${oct[3]}" -eq 0 ]] || return 1
    return 0
}

# Проверка пересечения двух подсетей. Если обе /24 — сравниваем prefix24.
# Если одна из подсетей шире /24 (например, WAN на /16) — используем python3
# (доступен на Ubuntu 22/24 by default) для честного overlap-чека.
cidrs_overlap() {
    local a="$1" b="$2"
    [[ -z "$a" || -z "$b" ]] && return 1
    if [[ "$a" == */24 && "$b" == */24 ]]; then
        [[ "$(net_prefix24 "$a")" == "$(net_prefix24 "$b")" ]]
        return $?
    fi
    python3 - "$a" "$b" <<'PY' 2>/dev/null
import sys, ipaddress
try:
    a = ipaddress.ip_network(sys.argv[1], strict=False)
    b = ipaddress.ip_network(sys.argv[2], strict=False)
    sys.exit(0 if a.overlaps(b) else 1)
except Exception:
    sys.exit(1)
PY
}
