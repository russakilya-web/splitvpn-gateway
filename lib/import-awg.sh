#!/bin/bash
# lib/import-awg.sh — три способа импортировать AmneziaWG-конфиг
# в /etc/amnezia/amneziawg/<iface>.conf.

# Куда awg-quick@<iface>.service ищет конфиг
AWG_CONF_DIR="/etc/amnezia/amneziawg"

# Минимальная валидация: должен быть хотя бы [Interface] с PrivateKey и [Peer] с
# PublicKey/Endpoint. Без этого awg-quick не поднимет туннель — лучше упасть рано.
validate_awg_conf() {
    local conf="$1"
    local missing=()
    grep -q '^\[Interface\]' "$conf" || missing+=("[Interface]")
    grep -q '^\[Peer\]'      "$conf" || missing+=("[Peer]")
    grep -qE '^\s*PrivateKey\s*='   "$conf" || missing+=("PrivateKey")
    grep -qE '^\s*PublicKey\s*='    "$conf" || missing+=("PublicKey")
    grep -qE '^\s*Endpoint\s*='     "$conf" || missing+=("Endpoint")
    grep -qE '^\s*AllowedIPs\s*='   "$conf" || missing+=("AllowedIPs")

    if [[ ${#missing[@]} -gt 0 ]]; then
        err "В конфиге отсутствуют поля: ${missing[*]}"
        return 1
    fi
}

# Кладёт конфиг по конечному пути с правильными правами и атомарно (через mv).
install_awg_conf() {
    local src="$1" iface="$2"
    local dst="${AWG_CONF_DIR}/${iface}.conf"
    mkdir -p "$AWG_CONF_DIR"
    install -m 600 "$src" "$dst"
    log "Конфиг установлен: $dst"
}

# Импорт из существующего .conf файла (с диска).
import_from_file() {
    local path="$1" iface="$2"
    if [[ ! -f "$path" ]]; then
        err "Файл не найден: $path"
        return 1
    fi
    validate_awg_conf "$path" || return 1
    install_awg_conf "$path" "$iface"
}

# Импорт через интерактивный paste в терминале (Ctrl-D для завершения).
import_from_paste() {
    local iface="$1"
    local tmp; tmp=$(mktemp)
    echo "Вставьте содержимое .conf файла, затем нажмите Ctrl-D:" >&2
    cat > "$tmp"
    if [[ ! -s "$tmp" ]]; then
        err "Пустой ввод"
        rm -f "$tmp"
        return 1
    fi
    if ! validate_awg_conf "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    install_awg_conf "$tmp" "$iface"
    rm -f "$tmp"
}

# Импорт из vpn://-ссылки AmneziaVPN.
# Аргументы: $1 — ссылка, $2 — имя интерфейса, $3 — путь к parse-vpn-url.py.
import_from_vpn_url() {
    local link="$1" iface="$2" parser="$3"
    if [[ -z "$link" ]]; then
        err "Пустая vpn:// ссылка"
        return 1
    fi
    if [[ ! -x "$parser" && ! -f "$parser" ]]; then
        err "Парсер не найден: $parser"
        return 1
    fi
    local tmp; tmp=$(mktemp)
    if ! python3 "$parser" "$link" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! validate_awg_conf "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    install_awg_conf "$tmp" "$iface"
    rm -f "$tmp"
}

# Интерактивное меню выбора способа.
# Аргументы: $1 — имя интерфейса, $2 — путь к parse-vpn-url.py.
import_awg_interactive() {
    local iface="$1" parser="$2"
    local choice
    while true; do
        {
            echo ""
            echo "Откуда взять AmneziaWG-конфиг?"
            echo "  1) Указать путь к .conf файлу"
            echo "  2) Вставить vpn://… ссылку"
            echo "  3) Вставить содержимое .conf вручную (paste, Ctrl-D в конце)"
        } >&2
        read -r -p "  Выбор [1]: " choice >&2 || choice=""
        choice="${choice:-1}"
        case "$choice" in
            1)
                local path
                read -r -p "  Путь к .conf: " path >&2 || path=""
                import_from_file "$path" "$iface" && return 0
                ;;
            2)
                local link
                read -r -p "  vpn:// ссылка: " link >&2 || link=""
                import_from_vpn_url "$link" "$iface" "$parser" && return 0
                ;;
            3)
                import_from_paste "$iface" && return 0
                ;;
            *)
                echo "  Введите 1, 2 или 3" >&2
                ;;
        esac
        echo "  Импорт не удался — попробуйте ещё раз." >&2
    done
}
