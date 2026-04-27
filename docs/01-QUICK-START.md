# 🚀 Quick Start

## Что это?

`splitvpn-gateway` — Ubuntu-сервер, который превращает домашнюю сеть в умный
VPN-шлюз с тремя режимами для разных устройств:

| Зона       | IP-адреса (по умолчанию) | Что делает                        |
|------------|--------------------------|-----------------------------------|
| **VPN**    | `<LAN>.20-30`            | Весь трафик через VPN             |
| **Bypass** | `<LAN>.31-49`            | Весь трафик напрямую              |
| **Split**  | Остальные                | Только указанные домены через VPN |

`<LAN>` — первые три октета твоей LAN-подсети (по умолчанию `192.168.1`).

Туннель — **AmneziaWG** (WireGuard с обфускацией DPI). Поднимается полностью
headless, без GUI.

---

## Что нужно

- Сервер с **Ubuntu 22.04 / 24.04 LTS** (x86_64)
- **Два сетевых интерфейса**: один в роутер/интернет (WAN), второй в локалку (LAN)
- Готовый AmneziaWG-конфиг — `.conf` файл, `vpn://...` ссылка из AmneziaVPN-клиента
  или содержимое для paste

---

## Установка в одну команду

```bash
curl -sSL https://raw.githubusercontent.com/russakilya-web/splitvpn-gateway/master/install.sh | sudo bash
```

Мастер последовательно:

1. Установит `amneziawg`, `dnsmasq`, `isc-dhcp-server` и остальное.
2. Покажет список сетевых интерфейсов и попросит выбрать **WAN** и **LAN**
   (default route автоматически предлагается как WAN).
3. Спросит, как импортировать AmneziaWG-конфиг — три варианта:
   - **`.conf` файл** (если уже скопирован на сервер),
   - **`vpn://...` ссылка** (экспортируется из AmneziaVPN GUI: Settings → Share),
   - **paste** содержимого `.conf` прямо в терминал.
4. Сгенерирует `/etc/vpn-split/config.env`, настроит DHCP/DNS/iptables,
   поднимет туннель и watchdog.

После установки откроется веб-интерфейс на `http://<LAN_IP>:8080`.

### Non-interactive (для CI/Ansible)

```bash
sudo ./install.sh --yes \
    --wan=enp2s0 --lan=enp3s0 \
    --awg-config=/root/awg0.conf
```

---

## Проверка после установки

```bash
sudo /usr/local/sbin/test-setup.sh   # smoke-проверка всех компонентов
sudo awg show                         # handshake AmneziaWG-туннеля
journalctl -u vpn-gateway-watchdog -f # лог watchdog
```

---

## Что дальше

- **Подключить устройства** к LAN-интерфейсу сервера (или назначить ему DHCP-зону на роутере).
- **Распределить устройства по зонам** — см. [02-ZONES.md](02-ZONES.md) и [03-DHCP.md](03-DHCP.md).
- **Добавить домены** в split-зону через веб-UI или редактируя `/opt/vpn-gateway/vpn-domains.txt`.
- При проблемах — [04-TROUBLESHOOTING.md](04-TROUBLESHOOTING.md).
