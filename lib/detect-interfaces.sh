#!/bin/bash
# lib/detect-interfaces.sh — автодетект и интерактивный выбор сетевых интерфейсов.

# Возвращает имя интерфейса, через который сейчас идёт default route.
# Если default route нет (свежий сервер без интернета) — пустая строка.
detect_wan_iface() {
    ip -4 route show default 2>/dev/null | awk '/^default/ {print $5; exit}'
}

# Возвращает первую подсеть на интерфейсе в формате CIDR (например, "192.168.1.0/24").
# Пустая строка, если у интерфейса нет IPv4 или интерфейс не существует.
get_iface_subnet() {
    local iface="$1"
    [[ -z "$iface" ]] && return
    # ip -4 -o addr показывает строки вида:
    #   "2: eth0    inet 192.168.1.42/24 brd 192.168.1.255 scope global ..."
    # Поле $4 = "192.168.1.42/24" — это IP/prefix хоста, а не подсети.
    # Превращаем в network через python3 (доступен на Ubuntu 22/24 by default).
    local host_cidr
    host_cidr=$(ip -4 -o addr show dev "$iface" 2>/dev/null \
                  | awk '{print $4; exit}')
    [[ -z "$host_cidr" ]] && return
    python3 - "$host_cidr" <<'PY' 2>/dev/null
import sys, ipaddress
try:
    n = ipaddress.ip_network(sys.argv[1], strict=False)
    print(f"{n.network_address}/{n.prefixlen}")
except Exception:
    pass
PY
}

# Список физических интерфейсов кроме lo, docker, wg/awg, br-, veth.
# Возвращает по одному имени на строку.
list_physical_ifaces() {
    ip -o link show 2>/dev/null \
        | awk -F': ' '{print $2}' \
        | awk '{print $1}' \
        | grep -Ev '^(lo|docker|wg|awg|amn|br-|veth|tun|tap|virbr)' \
        | sort -u
}

# Печатает табличку "1) <iface>  UP  <ip>  [рекомендуется]" в stderr для меню.
# Аргументы: $1 — выделенный кандидат (рекомендация), $2... — список интерфейсов.
print_iface_menu() {
    local recommended="$1"; shift
    local i=1
    local iface
    for iface in "$@"; do
        local state ip4 marker=""
        state=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "?")
        ip4=$(ip -4 -o addr show dev "$iface" 2>/dev/null \
                | awk '{print $4}' | head -n1)
        [[ -z "$ip4" ]] && ip4="—"
        if [[ "$iface" == "$recommended" ]]; then
            marker="  [рекомендуется]"
        fi
        printf "  %d) %-12s  %-4s  %-18s%s\n" "$i" "$iface" "$state" "$ip4" "$marker"
        ((i++))
    done
}

# Интерактивный выбор интерфейса.
# Аргументы: $1 — заголовок (для подсказки пользователю), $2 — рекомендуемый,
# $3... — список доступных интерфейсов.
# Печатает выбранное имя на stdout. Все промпты идут в stderr, чтобы их можно
# было захватить через `iface=$(pick_interface_interactive ...)`.
pick_interface_interactive() {
    local title="$1"; shift
    local recommended="$1"; shift
    local ifaces=("$@")
    local default_idx=1 i

    if [[ ${#ifaces[@]} -eq 0 ]]; then
        echo "ERROR: нет доступных сетевых интерфейсов" >&2
        return 1
    fi

    # Найдём индекс рекомендованного (для default ответа на enter)
    for i in "${!ifaces[@]}"; do
        if [[ "${ifaces[$i]}" == "$recommended" ]]; then
            default_idx=$((i + 1))
            break
        fi
    done

    {
        echo ""
        echo "$title"
        print_iface_menu "$recommended" "${ifaces[@]}"
    } >&2

    local choice
    while true; do
        read -r -p "  Выбор [${default_idx}]: " choice >&2 || choice=""
        choice="${choice:-$default_idx}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ifaces[@]} )); then
            echo "${ifaces[$((choice - 1))]}"
            return 0
        fi
        echo "  Введите число от 1 до ${#ifaces[@]}" >&2
    done
}
