# 🔧 Настройка DHCP

## Конфигурационный файл

Файл: `/etc/dhcp/dhcpd.conf`

---

## Структура конфигурации

```bash
# Основные параметры
default-lease-time 600;    # Время аренды по умолчанию (10 минут)
max-lease-time 7200;       # Максимальное время аренды (2 часа)
authoritative;             # Этот сервер — главный DHCP

# Описание подсети
subnet 10.10.10.0 netmask 255.255.255.0 {
    # Пул для Split Zone (динамическая выдача)
    range 10.10.10.50 10.10.10.199;
    
    option routers 10.10.10.1;           # Шлюз
    option domain-name-servers 10.10.10.1;  # DNS (dnsmasq)
    option broadcast-address 10.10.10.255;
}

# Статические привязки для устройств
host device-name {
    hardware ethernet AA:BB:CC:DD:EE:FF;  # MAC-адрес
    fixed-address 10.10.10.XX;           # Фиксированный IP
}
```

---

## Текущие устройства

### Bypass Zone (10.10.10.31-49)

```bash
# Xiaomi робот-пылесос (напрямую, без VPN)
host xiaomi_vacuum {
    hardware ethernet f0:b0:40:5f:73:4b;
    fixed-address 10.10.10.31;
}
```

### VPN Zone (10.10.10.20-30)

```bash
# Пример: Smart TV для Netflix
# host samsung_tv {
#     hardware ethernet 12:34:56:78:9a:bc;
#     fixed-address 10.10.10.23;
# }
```

---

## Как добавить устройство

### Шаг 1: Узнать MAC-адрес

**На устройстве:**
- **Windows:** `ipconfig /all` → "Physical Address"
- **macOS/Linux:** `ifconfig | grep ether`
- **Android/iOS:** Настройки → О телефоне → MAC-адрес Wi-Fi

**На сервере (из выданных адресов):**
```bash
cat /var/lib/dhcp/dhcpd.leases | grep -A5 "binding state active"
```

### Шаг 2: Добавить в конфигурацию

```bash
# Редактировать конфиг
sudo nano /etc/dhcp/dhcpd.conf

# Добавить запись
host my-device {
    hardware ethernet AA:BB:CC:DD:EE:FF;
    fixed-address 10.10.10.XX;  # 20-30 для VPN, 31-49 для bypass
}
```

### Шаг 3: Применить изменения

```bash
sudo systemctl restart isc-dhcp-server
sudo systemctl status isc-dhcp-server
```

---

## Команды управления

```bash
# Перезапустить DHCP после изменений
sudo systemctl restart isc-dhcp-server

# Проверить статус
sudo systemctl status isc-dhcp-server

# Посмотреть логи
sudo journalctl -u isc-dhcp-server -f

# Проверить конфигурацию на ошибки
sudo dhcpd -t -cf /etc/dhcp/dhcpd.conf

# Посмотреть активные аренды
cat /var/lib/dhcp/dhcpd.leases | grep -A10 "binding state active"
```

---

## Диапазоны IP

| Диапазон | Зона | Описание |
|----------|------|----------|
| 10.10.10.20-30 | VPN | Весь трафик через VPN |
| 10.10.10.31-49 | Bypass | Весь трафик напрямую |
| 10.10.10.50-199 | Split | По доменам (DNS-based) |

---

## Типичные ошибки

### 1. "No subnet declaration for interface"

DHCP запустился до настройки интерфейса. Перезапустите:
```bash
sudo systemctl restart isc-dhcp-server
```

### 2. "No free leases"

Пул адресов заполнен. Уменьшите время аренды или расширьте range.

### 3. Сервис не запускается

```bash
# Проверить синтаксис
sudo dhcpd -t -cf /etc/dhcp/dhcpd.conf

# Посмотреть подробности ошибки
sudo journalctl -u isc-dhcp-server -n 30
```
