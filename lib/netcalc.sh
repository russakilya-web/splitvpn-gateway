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
