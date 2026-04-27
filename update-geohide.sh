#!/bin/bash
#
# GeoHide DNS Update Script
# Скачивает hosts файл для обхода геоблокировки
#

set -e

GEOHIDE_URL="https://raw.githubusercontent.com/Internet-Helper/GeoHideDNS/refs/heads/main/hosts/hosts"
GEOHIDE_FILE="/opt/vpn-gateway/geohide-hosts.txt"
CUSTOM_FILE="/opt/vpn-gateway/custom-hosts.txt"
VPN_DOMAINS_FILE="/opt/vpn-gateway/vpn-domains.txt"
BACKUP_DIR="/opt/vpn-gateway/backups"
LOG_FILE="/var/log/vpn-gateway-geohide.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
    log "ERROR: $1"
    exit 1
}

# Создаём директории если не существуют
ensure_dirs() {
    mkdir -p "$(dirname "$GEOHIDE_FILE")"
    mkdir -p "$BACKUP_DIR"
}

# Скачивание hosts файла
download_hosts() {
    log "Downloading GeoHide hosts from GitHub..."
    
    local temp_file="/tmp/geohide-hosts-$$.txt"
    
    if curl -fsSL --connect-timeout 30 --max-time 120 "$GEOHIDE_URL" -o "$temp_file"; then
        # Проверяем, что файл не пустой и содержит hosts записи
        if [[ -s "$temp_file" ]] && grep -qE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" "$temp_file"; then
            log "Download successful, validating..."
            
            local line_count=$(wc -l < "$temp_file")
            log "Downloaded $line_count lines"
            
            # Бэкап старого файла
            if [[ -f "$GEOHIDE_FILE" ]]; then
                cp "$GEOHIDE_FILE" "$BACKUP_DIR/geohide-hosts-$(date +%Y%m%d-%H%M%S).txt"
                # Удаляем старые бэкапы (оставляем последние 7)
                ls -t "$BACKUP_DIR"/geohide-hosts-*.txt 2>/dev/null | tail -n +8 | xargs -r rm
            fi
            
            # Заменяем файл
            mv "$temp_file" "$GEOHIDE_FILE"
            chmod 644 "$GEOHIDE_FILE"
            
            log "GeoHide hosts updated successfully ($line_count lines)"
            return 0
        else
            log "ERROR: Downloaded file is empty or invalid"
            rm -f "$temp_file"
            return 1
        fi
    else
        log "ERROR: Failed to download from $GEOHIDE_URL"
        rm -f "$temp_file"
        return 1
    fi
}

# Создаём пользовательский файл если не существует
ensure_custom_file() {
    if [[ ! -f "$CUSTOM_FILE" ]]; then
        log "Creating custom hosts file..."
        cat > "$CUSTOM_FILE" << 'EOF'
# Custom Hosts File
# Ваши собственные DNS записи для обхода геоблокировки
# Формат: IP DOMAIN
#
# Примеры:
# 104.16.99.35 example.com
# 45.155.204.190 blocked-service.com
#
# Этот файл НЕ перезаписывается при автообновлении.
# Добавляйте сюда свои записи.

EOF
        chmod 644 "$CUSTOM_FILE"
        log "Custom hosts file created"
    fi
}

# Фильтр: удалить из geohide-hosts.txt записи для доменов, которые уже есть
# в vpn-domains.txt. Иначе dnsmasq отдаст GeoHide-IP вместо реального, и
# трафик пойдёт через VPN на GeoHide-фронт (двойной обход, теряется
# geo-выход VPN, лишний hop).
# Поддерживает wildcard в vpn-domains.txt: "*.example.com" покрывает
# example.com и любой *.example.com.
filter_vpn_domains() {
    if [[ ! -f "$VPN_DOMAINS_FILE" ]]; then
        log "VPN domains file not found ($VPN_DOMAINS_FILE), skipping filter"
        return 0
    fi

    local before after removed
    before=$(grep -cE "^[0-9a-fA-F:.]+\s" "$GEOHIDE_FILE" 2>/dev/null || echo 0)

    awk -v vpn_list="$VPN_DOMAINS_FILE" '
        BEGIN {
            while ((getline line < vpn_list) > 0) {
                gsub(/^[ \t]+|[ \t]+$/, "", line)
                if (line == "" || line ~ /^#/) continue
                line = tolower(line)
                if (line ~ /^\*\./) {
                    wildcard[substr(line, 3)] = 1
                } else {
                    exact[line] = 1
                }
            }
            close(vpn_list)
        }
        # Hosts-запись = первое поле похоже на IP (v4 или v6) и есть >=2 колонки.
        # Остальное (комментарии, пустые строки, прочее) — passthrough.
        {
            if (NF >= 2 && $1 ~ /^[0-9a-fA-F:.]+$/) {
                d = tolower($2)
                if (d in exact) next
                drop = 0
                for (s in wildcard) {
                    if (d == s) { drop = 1; break }
                    sl = length(s)
                    dl = length(d)
                    if (dl > sl + 1 && substr(d, dl - sl) == "." s) { drop = 1; break }
                }
                if (drop) next
            }
            print
        }
    ' "$GEOHIDE_FILE" > "$GEOHIDE_FILE.tmp" && mv "$GEOHIDE_FILE.tmp" "$GEOHIDE_FILE"

    after=$(grep -cE "^[0-9a-fA-F:.]+\s" "$GEOHIDE_FILE" 2>/dev/null || echo 0)
    removed=$((before - after))

    if [[ $removed -gt 0 ]]; then
        log "Filtered out $removed entries that overlap with vpn-domains.txt ($before -> $after)"
    else
        log "No overlap between geohide-hosts and vpn-domains.txt (entries: $after)"
    fi
}

# Перезагрузка dnsmasq
reload_dnsmasq() {
    log "Reloading dnsmasq..."
    
    if systemctl is-active --quiet dnsmasq; then
        if systemctl reload dnsmasq; then
            log "dnsmasq reloaded successfully"
        else
            log "WARNING: Failed to reload dnsmasq, trying restart..."
            systemctl restart dnsmasq
        fi
    else
        log "WARNING: dnsmasq is not running"
    fi
}

# Показать статистику
show_stats() {
    local geohide_count=0
    local custom_count=0
    
    if [[ -f "$GEOHIDE_FILE" ]]; then
        geohide_count=$(grep -cE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" "$GEOHIDE_FILE" 2>/dev/null || echo 0)
    fi
    
    if [[ -f "$CUSTOM_FILE" ]]; then
        custom_count=$(grep -cE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" "$CUSTOM_FILE" 2>/dev/null || echo 0)
    fi
    
    log "Statistics: GeoHide=$geohide_count entries, Custom=$custom_count entries"
}

# Основная функция
main() {
    log "=== GeoHide DNS Update ==="
    
    ensure_dirs
    ensure_custom_file
    
    if download_hosts; then
        filter_vpn_domains
        reload_dnsmasq
        show_stats
        log "=== Update completed ==="
        exit 0
    else
        log "=== Update failed ==="
        exit 1
    fi
}

# Обработка аргументов
case "${1:-}" in
    --force)
        log "Force update requested"
        main
        ;;
    --stats)
        show_stats
        ;;
    --help)
        echo "Usage: $0 [--force|--stats|--help]"
        echo "  --force  Force download even if file exists"
        echo "  --stats  Show current statistics"
        echo "  --help   Show this help"
        ;;
    *)
        main
        ;;
esac
