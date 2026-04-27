# 🔍 Troubleshooting

Параметры (`$WAN_IF`, `$LAN_IF`, `$VPN_IF`) ниже — это переменные из
`/etc/vpn-split/config.env`. Подставьте свои значения или загрузите конфиг:

```bash
. /etc/vpn-split/config.env
```

## Быстрая диагностика

```bash
sudo /usr/local/sbin/test-setup.sh
```

---

## AmneziaWG-туннель не поднимается

```bash
# Статус сервиса
sudo systemctl status awg-quick@${VPN_IF}

# Полный лог
sudo journalctl -u awg-quick@${VPN_IF} -n 100

# Существует ли интерфейс
ip link show ${VPN_IF}

# Есть ли handshake (последний)
sudo awg show ${VPN_IF} latest-handshakes
```

Типичные причины:
- **Конфиг не подложен** → `/etc/amnezia/amneziawg/${VPN_IF}.conf` отсутствует.
  Перезапустите импорт: `sudo install.sh` или вручную скопируйте `.conf`.
- **kernel-модуль не собрался** → `modprobe amneziawg` падает. Поставьте
  `linux-headers-$(uname -r)` и `sudo dpkg-reconfigure amneziawg-dkms`.
- **Endpoint недоступен** → проверьте, что VPN-сервер живой:
  `nc -uvz <endpoint-host> <endpoint-port>`.

---

## dnsmasq не запускается (порт 53 занят)

```bash
sudo ss -tulpn | grep :53
# Если виден systemd-resolved — он держит порт 53:
sudo systemctl restart systemd-resolved   # после установки stub-listener должен быть отключен
sudo systemctl restart dnsmasq
```

---

## Web-UI недоступен

```bash
sudo systemctl status iplist-web
sudo ss -tulpn | grep :8080
sudo journalctl -u iplist-web -f
```

Веб-UI биндится **только на `$LAN_IP:8080`** — из WAN он недоступен.
Проверьте, что заходите с устройства внутри LAN.

---

## Трафик не идёт через VPN

```bash
# 1. Туннель поднят?
ip link show ${VPN_IF}
sudo awg show ${VPN_IF}

# 2. Правила маршрутизации
ip rule show
ip route show table vpn

# 3. Проверка через какой интерфейс уйдёт пакет
ip route get 8.8.8.8 from <client_ip>

# 4. Для split-зоны — попал ли IP в ipset
sudo ipset list vpn_domains | head -20

# 5. Маркировка пакетов
sudo iptables -t mangle -L PREROUTING -v
```

Решение:
```bash
# Перезапустить туннель
sudo systemctl restart awg-quick@${VPN_IF}

# Заново применить routing
sudo /usr/local/sbin/routing-setup.sh

# Сбросить conntrack (если старые сессии застряли вне VPN)
sudo conntrack -F
```

---

## DHCP не выдаёт адреса

```bash
sudo systemctl status isc-dhcp-server
sudo dhcpd -t                    # проверка конфига
sudo ss -tulpn | grep :67
sudo journalctl -u isc-dhcp-server -n 100
```

Частая причина: `INTERFACESv4` в `/etc/default/isc-dhcp-server` не указывает
на `$LAN_IF`. Проверьте — `setup.sh` должен был его выставить.

---

## Нет интернета после перезагрузки

```bash
cat /proc/sys/net/ipv4/ip_forward     # должно быть 1
sudo iptables -t nat -L POSTROUTING   # должно быть MASQUERADE
ip addr show                          # WAN получил IP по DHCP?
```

```bash
sudo sysctl -p /etc/sysctl.d/99-vpn-gateway.conf
sudo /usr/local/sbin/routing-setup.sh
sudo netplan apply
```

---

## Сайт из split-списка всё равно идёт мимо VPN

```bash
# Резолвится ли через наш dnsmasq?
nslookup youtube.com $(echo "$LAN_IP" | cut -d/ -f1)

# Попал ли IP в ipset
sudo ipset test vpn_domains <IP>
```

Часто помогает добавить связанные домены (CDN, аналитика). Для этого в
веб-UI есть вкладка **«Запись связей»** — она ловит все DNS-запросы клиента
и предлагает добавить новые домены в split-список.

---

## Логи

```bash
sudo journalctl -u awg-quick@${VPN_IF} -f
sudo journalctl -u vpn-gateway-watchdog -f
sudo journalctl -u dnsmasq -f
sudo journalctl -u isc-dhcp-server -f
sudo tail -f /var/log/vpn-gateway-setup.log
sudo tail -f /var/log/vpn-gateway-web.log
```
