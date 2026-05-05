# splitvpn-gateway-openwrt — split-VPN-шлюз для OpenWRT (минимальный)

Порт [splitvpn-gateway](../) на OpenWRT. Три зоны (VPN/Bypass/Split) поверх AmneziaWG, без LuCI и Flask.

## Требования

- OpenWRT **23.05.6** (другие версии не тестировались — см. ниже)
- **≥16 MB flash, ≥128 MB RAM** (на 8/64 не влезет)
- root-доступ по SSH
- интернет на роутере (для скачивания пакетов)
- готовый `awg0.conf` (от AmneziaVPN или скачанный с сервера)

## Установка

```sh
ssh root@192.168.1.1
wget -O- https://raw.githubusercontent.com/russakilya-web/splitvpn-gateway/master/openwrt/install.sh | sh
```

Скрипт сделает:
1. `opkg install dnsmasq-full ip-full kmod-nft-nat`
2. Скачает и поставит `kmod-amneziawg` + `amneziawg-tools` из [Slava-Shchipunov/awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt/releases)
3. Положит наши скрипты в `/usr/sbin/` и init-сервисы в `/etc/init.d/`
4. Спросит конфиг AmneziaWG (путь к файлу или paste)
5. Создаст `nftset vpn_domains` через uci, активирует сервисы

## Зоны (по дефолту, подсеть 192.168.1.0/24)

| Зона | IP-диапазон | Поведение |
|---|---|---|
| **VPN** | .20–.30 | Весь трафик через AmneziaWG (`awg0`) |
| **Bypass** | .31–.49 | Мимо VPN, DNS принудительно через 8.8.8.8 |
| **Split** | .50–.199 | Через VPN — только домены из списка `splitvpn domain list`, остальное — напрямую |

## Управление

```sh
splitvpn status                       # состояние зон, AWG, nftset
splitvpn domain add youtube.com       # добавить домен в split-зону
splitvpn domain add googlevideo.com
splitvpn domain remove youtube.com
splitvpn domain list
splitvpn reload                       # перечитать конфиг
splitvpn apply                        # применить правила прямо сейчас
```

Список доменов хранится в `/etc/config/dhcp` (секция `ipset`), резолвы dnsmasq автоматически попадают в nftset `inet fw4 vpn_domains`.

## Кастомизация

`/etc/config/vpn-split` — основной конфиг (uci-формат). Можно поменять диапазоны зон, fwmark, bypass-DNS.

```
config gateway 'main'
	option vpn_zone_start    '20'
	option vpn_zone_end      '30'
	option bypass_zone_start '31'
	option bypass_zone_end   '49'
	option split_zone_start  '50'
	option split_zone_end    '199'
	option external_dns      '8.8.8.8'
	...
```

После правки: `splitvpn apply`.

## Тестирование в VirtualBox (без железа)

```sh
# На macOS/Linux хосте
cd test
./setup-vbox.sh
VBoxManage startvm openwrt-gw --type gui
```

Скрипт скачает образ, создаст VM с двумя NIC (LAN=intnet 'splitlan', WAN=NAT). Тест-клиента подключай в ту же intnet `splitlan`. Подробности в плане: [pure-riding-boot.md](../../../.claude/plans/pure-riding-boot.md), секция Verification.

## Что НЕ входит в минимум

- LuCI-приложение (вместо CLI)
- Авто-обновление списка доменов с GitHub
- GeoHide
- IPv6 в split-зоне
- Web-UI

Это всё планируется во второй итерации — см. соответствующий issue в репо.

## Версии OpenWRT

- **23.05.6** — целевая (.ipk, AWG 2.0)
- **22.03.x** — должно работать, не проверено
- **24.10.x** — apk-формат, нужен другой релиз awg-openwrt — пока не поддерживается этим установщиком
- **25.x** — не поддерживается

## Файлы

```
openwrt/
├── install.sh                          # установщик (curl|sh)
├── README.md                           # этот файл
├── files/
│   ├── etc/
│   │   ├── config/vpn-split            # uci-конфиг
│   │   ├── init.d/amneziawg            # procd: awg-quick up awg0
│   │   ├── init.d/vpn-split            # procd: enforce + watchdog
│   │   └── uci-defaults/99-vpn-split   # bootstrap при первом boot
│   └── usr/sbin/
│       ├── vpn-split-enforce           # главный скрипт (3 зоны)
│       └── splitvpn                    # CLI-обёртка
└── test/
    └── setup-vbox.sh                   # VirtualBox-окружение для тестов
```

## Документация Ubuntu-версии

Полная архитектура, GeoHide, web-UI и прочее — в [README.md](../README.md) корня репозитория.
