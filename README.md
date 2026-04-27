# 🛡️ VPN Gateway для Ubuntu (AmneziaWG, headless)

Превращает Ubuntu сервер в умный VPN-шлюз с раздельной маршрутизацией трафика.
Туннель — **AmneziaWG** (WireGuard с обфускацией для обхода DPI), поднимается
полностью headless через `awg-quick@awg0.service`. **GUI AmneziaVPN не нужен.**

## ✨ Возможности

- **Туннель AmneziaWG**: kernel-модуль `amneziawg` из ppa:amnezia/ppa, без GUI
- **3 зоны маршрутизации**: VPN / Bypass / Split (по умолчанию /24)
- **Маршрутизация по доменам**: только указанные сайты идут через VPN
- **GeoHide DNS**: обход геоблокировки через DNS-подмену (автообновление)
- **Веб-интерфейс**: управление доменами и hosts через браузер (только LAN)
- **Установка в одну команду**: интерактивный мастер выбирает WAN/LAN и импортирует AWG-конфиг

## 🚀 Быстрый старт

```bash
# Один установщик, один вопрос-ответ — и шлюз готов.
curl -sSL https://raw.githubusercontent.com/russakilya-web/splitvpn-gateway/master/install.sh | sudo bash
```

Мастер последовательно:
1. поставит пакеты (включая `amneziawg` из PPA),
2. покажет список NIC и предложит выбрать **WAN** (default route) и **LAN**,
3. попросит AmneziaWG-конфиг — **тремя способами**:
   - указать путь к `.conf` файлу,
   - вставить `vpn://...` ссылку из AmneziaVPN,
   - вставить содержимое `.conf` вручную (Ctrl-D в конце),
4. сгенерирует `/etc/vpn-split/config.env`,
5. настроит DHCP / dnsmasq / iptables / policy-routing,
6. поднимет туннель и watchdog.

### Non-interactive (для автоматизации)

```bash
sudo ./install.sh --yes \
    --wan=enp2s0 --lan=enp3s0 \
    --awg-config=/root/awg0.conf
# либо
sudo ./install.sh --yes \
    --wan=enp2s0 --lan=enp3s0 \
    --awg-vpn-url='vpn://eyJjb250YWluZXJz...'
```

### Web-UI

После установки: `http://<LAN_IP>:8080` (по умолчанию `http://10.10.10.1:8080`).

## 📊 Зоны маршрутизации

| Зона       | IP-адреса (по умолчанию) | Поведение                  |
|------------|--------------------------|----------------------------|
| **VPN**    | `<LAN>.20-30`            | Весь трафик через VPN      |
| **Bypass** | `<LAN>.31-49`            | Весь трафик напрямую       |
| **Split**  | Остальные                | Только указанные домены через VPN |

`<LAN>` — первые три октета `LAN_NET` из `/etc/vpn-split/config.env`.

## 📖 Документация

| Документ | Описание |
|----------|----------|
| [01-QUICK-START.md](docs/01-QUICK-START.md) | Быстрый старт за 5 минут |
| [02-ZONES.md](docs/02-ZONES.md) | Зоны маршрутизации |
| [03-DHCP.md](docs/03-DHCP.md) | Настройка DHCP сервера |
| [04-TROUBLESHOOTING.md](docs/04-TROUBLESHOOTING.md) | Решение проблем |
| [05-COMMANDS.md](docs/05-COMMANDS.md) | Шпаргалка команд |
| [06-ARCHITECTURE.md](docs/06-ARCHITECTURE.md) | Архитектура системы |
| [07-GEOHIDE-DNS.md](docs/07-GEOHIDE-DNS.md) | Обход геоблокировки через DNS |

## 📁 Структура

```
install.sh                    # Bootstrap-мастер (curl | bash)
setup.sh                      # Основная установка (вызывается из install.sh)
routing-setup.sh              # Применение policy-based routing
vpn-split-enforce.sh          # Watchdog (следит за awg0, переустанавливает правила)
iplist-web-domains.py         # Flask web-UI (биндится на $LAN_IP:8080)
update-domains.sh             # Обновление dnsmasq из vpn-domains.txt
update-geohide.sh             # Обновление GeoHide hosts из GitHub
lib/
  common.sh                   # source /etc/vpn-split/config.env, get_wan_gw, логгер
  netcalc.sh                  # net_prefix24/net_gateway24/net_broadcast24
  detect-interfaces.sh        # автодетект WAN, интерактивный picker
  import-awg.sh               # file/url/paste импорт AWG-конфига
  parse-vpn-url.py            # парсер vpn://-ссылок AmneziaVPN
```

## 🔧 Технические требования

- **ОС**: Ubuntu 22.04 / 24.04 LTS (x86_64)
- **NIC**: минимум два — для WAN и LAN (имена выбираются интерактивно)
- **Туннель**: AmneziaWG kernel-module из `ppa:amnezia/ppa` (ставится автоматически)
- **Конфиг туннеля**: получается из AmneziaVPN-клиента (мобильного/десктопного)
  или от провайдера VPN

## 📝 Лицензия

MIT
