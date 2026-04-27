# 🏗️ Архитектура VPN Gateway

## Общая схема сети

```
┌─────────────────────────────────────────────────────────────────────┐
│                            ИНТЕРНЕТ                                  │
└─────────────────────────────────────────────────────────────────────┘
                    │                           │
                    │ WAN                       │ AmneziaWG-туннель
                    │ ($WAN_IF)                 │ ($VPN_IF, обычно awg0)
                    │ via DHCP                  │ awg-quick@awg0.service
         ┌──────────▼───────────────────────────▼──────────┐
         │                                                  │
         │              UBUNTU VPN GATEWAY                  │
         │                                                  │
         │  ┌─────────────┐  ┌──────────────┐              │
         │  │  dnsmasq    │  │  ipset       │              │
         │  │  (DNS)      │  │  (vpn_domains)│              │
         │  └─────────────┘  └──────────────┘              │
         │                                                  │
         │  ┌─────────────┐  ┌──────────────┐              │
         │  │  iptables   │  │  iproute2    │              │
         │  │  (NAT/Mark) │  │  (PBR)       │              │
         │  └─────────────┘  └──────────────┘              │
         │                                                  │
         └──────────────────────┬───────────────────────────┘
                                │ LAN ($LAN_IF)
                                │ $LAN_IP (по умолчанию 10.10.10.1/24)
                                │
         ┌──────────────────────▼───────────────────────────┐
         │                 ЛОКАЛЬНАЯ СЕТЬ                    │
         │                                                   │
         │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ │
         │  │ VPN Zone    │ │ Bypass Zone │ │ Split Zone  │ │
         │  │ .20-.30     │ │ .31-.49     │ │ остальные   │ │
         │  └─────────────┘ └─────────────┘ └─────────────┘ │
         │                                                   │
         │  📺 Smart TV    📱 Телефон     💻 Ноутбук       │
         │  🎮 PlayStation 🏦 Банк-апп    📱 Планшет       │
         │                                                   │
         └───────────────────────────────────────────────────┘
```

---

## Компоненты системы

### 1. DHCP Server (isc-dhcp-server)

**Назначение:** Выдаёт IP-адреса устройствам в локальной сети.

**Конфигурация:** `/etc/dhcp/dhcpd.conf`

```
Динамический пул: 10.10.10.50-199 (Split Zone)
VPN Zone:         10.10.10.20-30 (фиксированные MAC)
Bypass Zone:      10.10.10.31-49 (фиксированные MAC)
```

---

### 2. DNS Server (dnsmasq)

**Назначение:** 
- Резолвит DNS-запросы
- Добавляет IP в ipset для VPN-доменов

**Конфигурация:** `/etc/dnsmasq.d/`

Когда устройство запрашивает youtube.com:
1. dnsmasq получает IP от upstream DNS (8.8.8.8)
2. Если домен в списке → IP добавляется в ipset `vpn_domains`
3. Ответ отправляется устройству

---

### 3. ipset (vpn_domains)

**Назначение:** Хранит IP-адреса, которые должны идти через VPN.

```bash
# Тип: hash:ip с timeout 86400 секунд (24 часа)
# IP автоматически удаляются через 24 часа
```

---

### 4. iptables

**Назначение:** 
- NAT (MASQUERADE)
- Маркировка пакетов для Split Zone

**Правила** (имена интерфейсов берутся из `/etc/vpn-split/config.env`):

```bash
# NAT для WAN
-t nat POSTROUTING -o $WAN_IF -j MASQUERADE

# NAT для AmneziaWG
-t nat POSTROUTING -o $VPN_IF -j MASQUERADE

# Маркировка для Split Zone
-t mangle PREROUTING -i $LAN_IF -m set --match-set vpn_domains dst -j MARK --set-mark 0x1
```

---

### 5. iproute2 (Policy-Based Routing)

**Назначение:** Маршрутизация на основе source IP или fwmark.

**Таблицы:**
```
100 vpn    → default via $VPN_IF (awg0)
200 bypass → default via $WAN_GW (текущий шлюз провайдера, определяется динамически)
```

**Правила (ip rule):**
```
priority 10: from 10.10.10.20-30 → lookup vpn
priority 20: from 10.10.10.31-49 → lookup bypass
priority 30: fwmark 0x1           → lookup vpn
```

---

### 6. Веб-интерфейс (Flask)

**Назначение:** Управление списком доменов через браузер.

**Компоненты:**
- Python Flask приложение
- Порт 8080
- Systemd сервис `iplist-web`

**Функции:**
- Добавление/удаление доменов
- Отображение статуса VPN
- Статистика ipset

---

## Потоки трафика

### VPN Zone (`$LAN.20-30`)

```
Устройство → ip rule (priority 10) → table vpn → $VPN_IF → AmneziaWG → Интернет
```

### Bypass Zone (`$LAN.31-49`)

```
Устройство → ip rule (priority 20) → table bypass → $WAN_IF → WAN gateway → Интернет
```

### Split Zone (остальные)

**Трафик к VPN-доменам:**
```
Устройство → DNS запрос → dnsmasq → IP в ipset
            → TCP/UDP пакет → iptables mark 0x1
            → ip rule (priority 30) → table vpn → $VPN_IF → AmneziaWG
```

**Остальной трафик:**
```
Устройство → table main → $WAN_IF → WAN gateway → Интернет
```

---

## Файловая структура

```
/
├── etc/
│   ├── vpn-split/
│   │   └── config.env              # WAN_IF/LAN_IF/VPN_IF/LAN_NET/LAN_IP (создаёт install.sh)
│   ├── amnezia/amneziawg/
│   │   └── awg0.conf               # Конфиг AmneziaWG-туннеля (импортирован install.sh)
│   ├── dhcp/
│   │   └── dhcpd.conf              # DHCP конфигурация
│   ├── dnsmasq.d/
│   │   ├── vpn-gateway.conf        # Основная конфигурация dnsmasq
│   │   └── domains.d/
│   │       └── vpn-domains.conf    # Автогенерируемые правила ipset
│   ├── iproute2/
│   │   └── rt_tables               # Таблицы маршрутизации (vpn=100, bypass=200)
│   ├── netplan/
│   │   └── 99-vpn-gateway.yaml     # Статический IP на LAN-интерфейсе
│   ├── sysctl.d/
│   │   └── 99-vpn-gateway.conf     # IP forwarding
│   ├── systemd/system/
│   │   ├── vpn-gateway-watchdog.service
│   │   └── iplist-web.service
│   └── iptables/
│       └── rules.v4                # Сохранённые iptables
├── opt/vpn-gateway/
│   ├── vpn-domains.txt             # Список доменов (редактируемый)
│   ├── geohide-hosts.txt           # GeoHide DNS (автообновляется)
│   └── custom-hosts.txt            # Ваши hosts-записи
├── usr/local/lib/vpn-split/
│   ├── common.sh                   # load_config / get_wan_gw / логгер
│   ├── netcalc.sh                  # net_prefix24 / net_gateway24
│   ├── detect-interfaces.sh        # автодетект и picker WAN/LAN
│   ├── import-awg.sh               # 3 способа импорта AWG-конфига
│   └── parse-vpn-url.py            # парсер vpn://-ссылок AmneziaVPN
├── usr/local/sbin/
│   ├── routing-setup.sh            # Применение маршрутизации
│   ├── vpn-split-enforce.sh        # Watchdog
│   ├── iplist-web.py               # Веб-интерфейс (binds to $LAN_IP:8080)
│   ├── update-domains.sh           # Обновление dnsmasq
│   └── update-geohide.sh           # Обновление GeoHide
└── var/log/
    ├── vpn-gateway-setup.log       # Лог установки
    └── vpn-gateway-web.log         # Лог веб-интерфейса
```
