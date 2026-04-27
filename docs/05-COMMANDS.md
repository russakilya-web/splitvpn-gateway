# 📋 Команды-шпаргалка

Ниже `$WAN_IF`, `$LAN_IF`, `$VPN_IF` — переменные из `/etc/vpn-split/config.env`.
Загрузить их в текущий shell:

```bash
. /etc/vpn-split/config.env
```

## Самое частое

```bash
sudo /usr/local/sbin/test-setup.sh           # проверить, что всё ОК
sudo /usr/local/sbin/routing-setup.sh        # переприменить routing
sudo /usr/local/sbin/update-domains.sh       # пересобрать dnsmasq из vpn-domains.txt
sudo /usr/local/sbin/update-geohide.sh       # обновить GeoHide hosts
systemctl restart awg-quick@${VPN_IF}        # перезапустить туннель
```

## AmneziaWG

```bash
sudo awg show ${VPN_IF}                      # peers, handshake, traffic
sudo awg show ${VPN_IF} latest-handshakes
sudo awg-quick down ${VPN_IF} && sudo awg-quick up ${VPN_IF}
```

## Сетевые интерфейсы

```bash
ip link show
ip addr show
ip addr show ${LAN_IF}
ip addr show ${WAN_IF}
ip addr show ${VPN_IF}
```

## Маршрутизация

```bash
ip rule show
ip route show
ip route show table vpn
ip route show table bypass

# Куда уйдёт пакет с конкретного клиента
ip route get 8.8.8.8 from <client_ip>
# Что произойдёт с маркированным пакетом
ip route get 8.8.8.8 mark 0x1
```

## ipset (split-зона)

```bash
sudo ipset list vpn_domains
sudo ipset test vpn_domains <IP>
sudo ipset add  vpn_domains <IP>
sudo ipset del  vpn_domains <IP>
sudo ipset flush vpn_domains
```

## iptables

```bash
sudo iptables -t nat    -L -v
sudo iptables -t mangle -L PREROUTING -v
sudo iptables           -L FORWARD     -v
sudo iptables-save > /etc/iptables/rules.v4   # сохранить
```

## systemd-сервисы

```bash
sudo systemctl status  <service>
sudo systemctl restart <service>
sudo journalctl -u <service> -f
```

Наши сервисы:

| Сервис                    | Что делает                              |
|---------------------------|-----------------------------------------|
| `awg-quick@${VPN_IF}`     | AmneziaWG-туннель                       |
| `isc-dhcp-server`         | DHCP для LAN                            |
| `dnsmasq`                 | DNS + ipset для split-routing           |
| `iplist-web`              | Веб-интерфейс на `${LAN_IP}:8080`       |
| `vpn-gateway-watchdog`    | Сторож routing-правил                   |

## DNS / dnsmasq

```bash
nslookup google.com $(echo "$LAN_IP" | cut -d/ -f1)
dnsmasq --test
cat /etc/dnsmasq.d/domains.d/vpn-domains.conf
sudo systemctl reload dnsmasq
```

## DHCP

```bash
cat /var/lib/dhcp/dhcpd.leases
sudo dhcpd -t -cf /etc/dhcp/dhcpd.conf
```

## Файлы конфигурации

| Путь                                    | Описание |
|-----------------------------------------|----------|
| `/etc/vpn-split/config.env`             | WAN/LAN/VPN-параметры (генерирует install.sh) |
| `/etc/amnezia/amneziawg/${VPN_IF}.conf` | Конфиг AmneziaWG-туннеля |
| `/etc/dhcp/dhcpd.conf`                  | Настройка DHCP |
| `/etc/dnsmasq.d/vpn-gateway.conf`       | Основная конфигурация dnsmasq |
| `/etc/dnsmasq.d/domains.d/`             | Автогенерируемые ipset-правила |
| `/opt/vpn-gateway/vpn-domains.txt`      | Список доменов для split-зоны |
| `/opt/vpn-gateway/geohide-hosts.txt`    | GeoHide-hosts (автообновляется) |
| `/etc/netplan/99-vpn-gateway.yaml`      | Статический IP на LAN |
| `/etc/iproute2/rt_tables`               | Таблицы routing (vpn=100, bypass=200) |

## Порты

```bash
sudo ss -tulpn
sudo ss -tulpn | grep ':8080'   # web-UI
sudo ss -tulpn | grep ':53'     # dnsmasq
sudo ss -tulpn | grep ':67'     # dhcpd
```
