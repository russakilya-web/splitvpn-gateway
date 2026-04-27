# 🔓 GeoHide DNS — Обход геоблокировки

## Что это?

GeoHide DNS — функция подмены DNS-ответов для обхода геоблокировки. 
Когда клиент запрашивает заблокированный домен, dnsmasq возвращает рабочий IP вместо заблокированного.

---

## Как работает

```
Клиент запрашивает canva.com
        │
        ▼
   ┌─────────────────┐
   │    dnsmasq      │
   │                 │
   │ Проверяет:      │
   │ geohide-hosts   │
   │ custom-hosts    │
   └────────┬────────┘
            │
            ▼
Если домен найден в hosts:
   → Возвращает IP из hosts (например 45.155.204.190)

Если домен НЕ найден:
   → Обычный DNS запрос к upstream (8.8.8.8)
```

---

## Файлы

| Файл | Описание |
|------|----------|
| `/opt/vpn-gateway/geohide-hosts.txt` | Автоматически скачивается из GitHub. Можно редактировать, но перезатирается при обновлении |
| `/opt/vpn-gateway/custom-hosts.txt` | Ваши личные записи. **Никогда не перезатирается** |

### Формат hosts

```
IP_АДРЕС ДОМЕН
```

Пример:
```
45.155.204.190 canva.com
45.155.204.190 www.canva.com
95.182.120.241 amd.com
```

---

## Зоны применения

| Зона | GeoHide DNS |
|------|-------------|
| **VPN Zone** (10.10.10.20-30) | ✅ Применяется |
| **Split Zone** (остальные) | ✅ Применяется |
| **Bypass Zone** (10.10.10.31-49) | ❌ НЕ применяется |

Bypass-клиенты получают обычные DNS-ответы от 8.8.8.8, минуя локальный dnsmasq.

---

## Управление

### Через веб-интерфейс (рекомендуется)

1. Откройте http://10.10.10.1:8080
2. Перейдите на вкладку **"🔓 GeoHide DNS"**
3. Редактируйте GeoHide или Custom hosts
4. Нажмите "Сохранить"

### Через командную строку

```bash
# Принудительное обновление GeoHide hosts
sudo /usr/local/sbin/update-geohide.sh --force

# Посмотреть статистику
sudo /usr/local/sbin/update-geohide.sh --stats

# Редактировать custom hosts
sudo nano /opt/vpn-gateway/custom-hosts.txt

# Перезагрузить dnsmasq после изменений
sudo systemctl reload dnsmasq
```

---

## Автоматическое обновление

GeoHide hosts обновляется автоматически **каждый день в 4:00**.

Источник: https://github.com/Internet-Helper/GeoHideDNS

```bash
# Проверить cron задачу
crontab -l | grep update-geohide

# Посмотреть логи обновления
sudo tail -f /var/log/vpn-gateway-geohide.log
```

---

## Проверка работы

```bash
# Проверить, что домен резолвится через GeoHide
nslookup canva.com 10.10.10.1

# Ожидаемый результат:
# Name:    canva.com
# Address: 45.155.204.190  (IP из hosts файла)

# Проверить с Bypass устройства (должен вернуть реальный IP)
# На устройстве из Bypass зоны:
nslookup canva.com
# Вернёт реальный IP от провайдера
```

---

## Добавление своих записей

1. Откройте веб-интерфейс → GeoHide DNS → Custom Hosts
2. Добавьте записи в формате `IP ДОМЕН`:

```
# Мои записи
1.2.3.4 my-blocked-service.com
1.2.3.4 www.my-blocked-service.com
```

3. Сохраните

Либо через командную строку:
```bash
echo "1.2.3.4 my-blocked-service.com" | sudo tee -a /opt/vpn-gateway/custom-hosts.txt
sudo systemctl reload dnsmasq
```
