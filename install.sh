#!/bin/bash
#
# install.sh — bootstrap-установщик vpn-split.
#
# Запуск:
#   curl -sSL https://<repo>/install.sh | sudo bash
#   curl -sSL https://<repo>/install.sh | sudo bash -s -- --wan=enp2s0 --lan=enp3s0 --awg-config=/root/awg.conf
#
# Шаги:
#   1. Проверка ОС/root
#   2. Скачивание исходников проекта (если запущен через curl|bash)
#   3. Установка пакетов (включая amneziawg из ppa:amnezia/ppa)
#   4. Интерактивный выбор WAN/LAN с автодетектом
#   5. Импорт AmneziaWG-конфига (.conf файл / vpn://-ссылка / paste)
#   6. Запись /etc/vpn-split/config.env
#   7. Запуск setup.sh для всей основной конфигурации (DHCP, dnsmasq, routing, …)
#   8. Включение awg-quick@<iface>.service

set -euo pipefail

REPO_URL_DEFAULT="${VPN_SPLIT_REPO:-https://github.com/russakilya-web/splitvpn-gateway.git}"
REPO_BRANCH="${VPN_SPLIT_BRANCH:-master}"
SRC_DIR="${VPN_SPLIT_SRC:-/opt/vpn-split/src}"
LIB_DIR="/usr/local/lib/vpn-split"
CONFIG_FILE="/etc/vpn-split/config.env"

# Дефолты (могут быть переопределены через флаги CLI или интерактивно)
WAN_IF=""
LAN_IF=""
VPN_IF="awg0"
LAN_NET="192.168.1.0/24"
LAN_IP="192.168.1.1/24"
AWG_CONFIG_PATH=""
AWG_VPN_URL=""
ASSUME_YES=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

step()  { echo -e "${CYAN}[$1/8]${NC} $2"; }
ok()    { echo -e "  ${GREEN}OK${NC} $*"; }
warn()  { echo -e "  ${YELLOW}WARN${NC} $*"; }
die()   { echo -e "  ${RED}ERROR${NC} $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
install.sh — установка vpn-split (split VPN gateway на AmneziaWG).

Опции (все необязательные — без них запустится интерактивный мастер):
  --wan=IFACE          имя WAN-интерфейса (например, enp2s0)
  --lan=IFACE          имя LAN-интерфейса (например, enp3s0)
  --vpn-if=NAME        имя AmneziaWG-интерфейса (по умолчанию awg0)
  --lan-net=CIDR       LAN-подсеть /24 (по умолчанию 192.168.1.0/24)
  --awg-config=PATH    путь к готовому .conf файлу AmneziaWG
  --awg-vpn-url=URL    vpn://... ссылка из AmneziaVPN
  --src=PATH           где взять исходники (по умолчанию клонируется в /opt/vpn-split/src)
  --yes                non-interactive режим (требует --wan, --lan и один из --awg-*)
  -h, --help           эта подсказка
EOF
}

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --wan=*)         WAN_IF="${arg#*=}" ;;
            --lan=*)         LAN_IF="${arg#*=}" ;;
            --vpn-if=*)      VPN_IF="${arg#*=}" ;;
            --lan-net=*)     LAN_NET="${arg#*=}" ;;
            --awg-config=*)  AWG_CONFIG_PATH="${arg#*=}" ;;
            --awg-vpn-url=*) AWG_VPN_URL="${arg#*=}" ;;
            --src=*)         SRC_DIR="${arg#*=}" ;;
            --yes|-y)        ASSUME_YES=1 ;;
            -h|--help)       usage; exit 0 ;;
            *)               die "Неизвестный аргумент: $arg" ;;
        esac
    done
    # LAN_IP вычисляется как первый IP подсети + /24
    local prefix="${LAN_NET%.*/*}"
    LAN_IP="${prefix}.1/24"
}

check_os() {
    [[ $EUID -eq 0 ]] || die "Запустите от root (sudo)"
    [[ -f /etc/os-release ]] || die "/etc/os-release не найден — неизвестная ОС"
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID}:${VERSION_ID}" in
        ubuntu:22.04|ubuntu:24.04) ok "ОС: ${PRETTY_NAME}" ;;
        ubuntu:*) warn "Ubuntu ${VERSION_ID} не тестировался, продолжаю" ;;
        *) die "Поддерживается только Ubuntu 22.04/24.04, найдено: ${PRETTY_NAME}" ;;
    esac
}

fetch_sources() {
    # Если скрипт уже лежит рядом с остальным проектом (репо склонирован
    # вручную) — используем эту директорию вместо повторного клонирования.
    local self_dir; self_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
    if [[ -f "$self_dir/setup.sh" && -d "$self_dir/lib" ]]; then
        SRC_DIR="$self_dir"
        ok "Использую исходники из $SRC_DIR"
        return
    fi

    apt-get update -qq
    apt-get install -y -qq git
    if [[ -d "$SRC_DIR/.git" ]]; then
        git -C "$SRC_DIR" fetch --depth 1 origin "$REPO_BRANCH"
        git -C "$SRC_DIR" reset --hard "origin/${REPO_BRANCH}"
    else
        rm -rf "$SRC_DIR"
        mkdir -p "$(dirname "$SRC_DIR")"
        git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL_DEFAULT" "$SRC_DIR"
    fi
    ok "Скачан в $SRC_DIR"
}

install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq software-properties-common gnupg2 curl
    # PPA с amneziawg — собирает kernel-модуль через DKMS
    if ! apt-cache policy | grep -q "amnezia/ppa"; then
        add-apt-repository -y ppa:amnezia/ppa
    fi
    apt-get update -qq
    apt-get install -y -qq \
        amneziawg amneziawg-tools \
        dnsmasq ipset iptables-persistent \
        isc-dhcp-server \
        python3 python3-flask \
        qrencode conntrack
    # Проверим что awg-quick доступен
    command -v awg-quick >/dev/null || die "awg-quick не установился — проверьте, что PPA доступен"
    ok "Пакеты установлены (включая amneziawg, dnsmasq, isc-dhcp-server)"
}

install_libs() {
    mkdir -p "$LIB_DIR"
    install -m 644 "$SRC_DIR/lib/common.sh"           "$LIB_DIR/common.sh"
    install -m 644 "$SRC_DIR/lib/netcalc.sh"          "$LIB_DIR/netcalc.sh"
    install -m 644 "$SRC_DIR/lib/detect-interfaces.sh" "$LIB_DIR/detect-interfaces.sh"
    install -m 644 "$SRC_DIR/lib/import-awg.sh"       "$LIB_DIR/import-awg.sh"
    install -m 755 "$SRC_DIR/lib/parse-vpn-url.py"    "$LIB_DIR/parse-vpn-url.py"
    ok "Библиотеки установлены в $LIB_DIR"
}

choose_interfaces() {
    # shellcheck disable=SC1091
    . "$LIB_DIR/detect-interfaces.sh"

    local detected_wan; detected_wan=$(detect_wan_iface)
    local all_ifaces=()
    while IFS= read -r line; do all_ifaces+=("$line"); done < <(list_physical_ifaces)
    [[ ${#all_ifaces[@]} -gt 0 ]] || die "Не найдено ни одного физического NIC"

    if [[ -n "$detected_wan" ]]; then
        echo "  Обнаружен default route через: $detected_wan"
    else
        warn "Default route не обнаружен — предположите WAN сами"
    fi

    if [[ -z "$WAN_IF" ]]; then
        if [[ "$ASSUME_YES" -eq 1 ]]; then
            WAN_IF="$detected_wan"
            [[ -n "$WAN_IF" ]] || die "В --yes режиме нужен --wan=..."
        else
            WAN_IF=$(pick_interface_interactive \
                "WAN-интерфейс (внешний, к роутеру/интернету):" \
                "$detected_wan" "${all_ifaces[@]}")
        fi
    fi
    ok "WAN: $WAN_IF"

    if [[ -z "$LAN_IF" ]]; then
        # LAN-кандидат — первый интерфейс, не равный WAN
        local lan_candidates=()
        local recommended_lan=""
        local i
        for i in "${all_ifaces[@]}"; do
            if [[ "$i" != "$WAN_IF" ]]; then
                lan_candidates+=("$i")
                [[ -z "$recommended_lan" ]] && recommended_lan="$i"
            fi
        done
        [[ ${#lan_candidates[@]} -gt 0 ]] || die "Не осталось интерфейсов для LAN (нужен второй NIC)"

        if [[ "$ASSUME_YES" -eq 1 ]]; then
            LAN_IF="$recommended_lan"
        else
            LAN_IF=$(pick_interface_interactive \
                "LAN-интерфейс (к локальной сети):" \
                "$recommended_lan" "${lan_candidates[@]}")
        fi
    fi
    ok "LAN: $LAN_IF"

    [[ "$WAN_IF" != "$LAN_IF" ]] || die "WAN и LAN не могут быть одним и тем же интерфейсом"
}

import_awg() {
    # shellcheck disable=SC1091
    . "$LIB_DIR/common.sh"
    # shellcheck disable=SC1091
    . "$LIB_DIR/import-awg.sh"

    if [[ -n "$AWG_CONFIG_PATH" ]]; then
        import_from_file "$AWG_CONFIG_PATH" "$VPN_IF" \
            || die "Не удалось импортировать $AWG_CONFIG_PATH"
    elif [[ -n "$AWG_VPN_URL" ]]; then
        import_from_vpn_url "$AWG_VPN_URL" "$VPN_IF" "$LIB_DIR/parse-vpn-url.py" \
            || die "Не удалось распарсить vpn:// ссылку"
    elif [[ "$ASSUME_YES" -eq 1 ]]; then
        die "В --yes режиме нужен --awg-config=... или --awg-vpn-url=..."
    else
        import_awg_interactive "$VPN_IF" "$LIB_DIR/parse-vpn-url.py"
    fi
    ok "AmneziaWG-конфиг записан в /etc/amnezia/amneziawg/${VPN_IF}.conf"
}

write_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    umask 077
    cat > "$CONFIG_FILE" <<EOF
# /etc/vpn-split/config.env
# Сгенерировано install.sh $(date '+%F %T')
# Сетевые интерфейсы и подсети vpn-split. Меняйте только если знаете, что делаете.

WAN_IF=$WAN_IF
LAN_IF=$LAN_IF
VPN_IF=$VPN_IF
LAN_NET=$LAN_NET
LAN_IP=$LAN_IP
EOF
    ok "Записано: $CONFIG_FILE"
}

run_setup() {
    bash "$SRC_DIR/setup.sh"
}

enable_awg_service() {
    systemctl enable --now "awg-quick@${VPN_IF}.service"
    sleep 1
    if ip link show "$VPN_IF" >/dev/null 2>&1; then
        ok "awg-quick@${VPN_IF} активен"
    else
        warn "Интерфейс $VPN_IF не поднялся — проверьте 'systemctl status awg-quick@${VPN_IF}'"
    fi
}

main() {
    parse_args "$@"

    step 1 "Проверка системы"
    check_os

    step 2 "Получение исходников"
    fetch_sources

    step 3 "Установка пакетов"
    install_packages

    step 4 "Установка библиотек"
    install_libs

    step 5 "Выбор сетевых интерфейсов"
    choose_interfaces

    step 6 "Импорт AmneziaWG-конфига"
    import_awg

    step 7 "Запись /etc/vpn-split/config.env и запуск setup.sh"
    write_config
    run_setup

    step 8 "Запуск AmneziaWG-туннеля"
    enable_awg_service

    echo ""
    echo -e "${GREEN}✅ Готово!${NC}"
    echo "  Web-UI:        http://${LAN_IP%/*}:8080"
    echo "  Status awg:    awg show $VPN_IF"
    echo "  Логи watchdog: journalctl -u vpn-gateway-watchdog -f"
    echo ""
    echo "  Ребут рекомендуется чтобы убедиться, что всё стартует автоматически."
}

main "$@"
