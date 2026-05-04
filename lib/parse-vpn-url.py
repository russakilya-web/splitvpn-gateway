#!/usr/bin/env python3
"""
parse-vpn-url.py — парсер AmneziaVPN-ссылок vpn://… в готовый AmneziaWG .conf.

Формат AmneziaVPN-ссылки:
    vpn:// + urlsafe_base64( zlib.compress( JSON ) )

JSON содержит массив контейнеров (containers); нас интересует контейнер
amnezia-awg, в котором есть поле awg.last_config — JSON-строка с настройками
WireGuard и обфускации (Jc/Jmin/Jmax/S1/S2/H1-H4 и опционально I1-I5).

Использование:
    python3 parse-vpn-url.py 'vpn://...'              # печатает .conf на stdout
    python3 parse-vpn-url.py 'vpn://...' awg0.conf    # пишет в файл

Зависимости: только stdlib. Работает на Python 3.8+ (используется на Ubuntu 22.04).
"""
import sys
import base64
import zlib
import json
import os


def decode_link(link: str) -> dict:
    if not link.startswith("vpn://"):
        raise ValueError("Ссылка должна начинаться с vpn://")
    raw = link[len("vpn://"):].strip()
    # urlsafe_b64decode требует длину, кратную 4 — добавим padding
    pad = "=" * (-len(raw) % 4)
    try:
        blob = base64.urlsafe_b64decode(raw + pad)
    except Exception as exc:
        raise ValueError(f"base64 decode error: {exc}")

    # Реальный формат AmneziaVPN client-share (видно в исходниках клиента):
    #   [4 байта BE uint32 = uncompressed size] + [zlib-stream JSON]
    # Старые версии клиента и некоторые форки кладут только zlib без префикса.
    # Пробуем варианты в порядке "новый -> старый":
    #   1) skip 4 bytes -> zlib (with header)
    #   2) zlib (with header) с самого начала
    #   3) raw deflate с самого начала
    candidates = [
        ("skip 4-byte prefix + zlib", blob[4:], zlib.MAX_WBITS),
        ("zlib (with header)",        blob,     zlib.MAX_WBITS),
        ("raw deflate",               blob,     -zlib.MAX_WBITS),
    ]
    last_err = None
    for label, data, wbits in candidates:
        try:
            plain = zlib.decompress(data, wbits)
            return json.loads(plain.decode("utf-8"))
        except (zlib.error, json.JSONDecodeError) as e:
            last_err = f"{label}: {e}"
    raise ValueError(f"не удалось распаковать payload (попробованы все варианты). Последняя ошибка: {last_err}")


def find_awg_section(payload: dict) -> dict:
    """Возвращает словарь с полями awg-конфига (Interface + Peer + obfs)."""
    for c in payload.get("containers", []):
        if c.get("container") not in ("amnezia-awg", "awg"):
            continue
        awg = c.get("awg") or {}
        last = awg.get("last_config")
        if not last:
            continue
        try:
            return json.loads(last) if isinstance(last, str) else last
        except json.JSONDecodeError as exc:
            raise ValueError(f"awg.last_config не JSON: {exc}")
    raise ValueError("В ссылке нет AmneziaWG-контейнера (поддерживаем только amnezia-awg)")


def build_conf(cfg: dict) -> str:
    """Собирает текст awg0.conf из распарсенного словаря."""
    # AmneziaVPN отдаёт конфиг в виде flat-словаря с ключами под обе секции.
    # Пример полей: client_priv_key, client_ip, server_pub_key, hostName,
    # port, psk_key, Jc, Jmin, Jmax, S1, S2, H1, H2, H3, H4, mtu, allowed_ips...

    def get(*names, default=None):
        for n in names:
            if n in cfg and cfg[n] not in (None, ""):
                return cfg[n]
        return default

    private_key = get("client_priv_key", "PrivateKey")
    address = get("client_ip", "Address")
    # AmneziaVPN отдаёт client_ip без маски (например, "10.8.1.27").
    # awg-quick этого не любит — дописываем /32 для IPv4 / /128 для IPv6 если
    # маска отсутствует.
    if address and "/" not in address:
        address = f"{address}/128" if ":" in address else f"{address}/32"
    dns = get("client_dns", "DNS", default="1.1.1.1, 1.0.0.1")
    mtu = get("mtu", "MTU")

    public_key = get("server_pub_key", "PublicKey")
    psk = get("psk_key", "PresharedKey")
    endpoint_host = get("hostName", "Endpoint")
    endpoint_port = get("port", "ListenPort")
    allowed_ips = get("allowed_ips", "AllowedIPs", default="0.0.0.0/0, ::/0")
    keepalive = get("persistent_keep_alive", "PersistentKeepalive", default=25)

    # Если allowed_ips пришёл списком — склеиваем
    if isinstance(allowed_ips, list):
        allowed_ips = ", ".join(allowed_ips)

    if not all([private_key, address, public_key, endpoint_host, endpoint_port]):
        missing = [k for k, v in {
            "PrivateKey": private_key, "Address": address,
            "PublicKey": public_key, "Endpoint host": endpoint_host,
            "Endpoint port": endpoint_port,
        }.items() if not v]
        raise ValueError(f"В конфиге отсутствуют обязательные поля: {', '.join(missing)}")

    lines = ["[Interface]"]
    lines.append(f"Address = {address}")
    lines.append(f"PrivateKey = {private_key}")
    lines.append(f"DNS = {dns}")
    if mtu:
        lines.append(f"MTU = {mtu}")

    # Параметры обфускации AmneziaWG. Если их нет — секция превращается в обычный
    # WireGuard, awg-quick это поддерживает.
    obfs_keys = ["Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4",
                 "H1", "H2", "H3", "H4",
                 "I1", "I2", "I3", "I4", "I5",
                 "J1", "J2", "J3", "ITIME"]
    for k in obfs_keys:
        if k in cfg and cfg[k] not in (None, ""):
            lines.append(f"{k} = {cfg[k]}")

    lines.append("")
    lines.append("[Peer]")
    lines.append(f"PublicKey = {public_key}")
    if psk:
        lines.append(f"PresharedKey = {psk}")
    lines.append(f"AllowedIPs = {allowed_ips}")
    lines.append(f"Endpoint = {endpoint_host}:{endpoint_port}")
    lines.append(f"PersistentKeepalive = {keepalive}")
    lines.append("")
    return "\n".join(lines)


def main(argv):
    if len(argv) < 2:
        print("Usage: parse-vpn-url.py 'vpn://...' [output.conf]", file=sys.stderr)
        return 2

    link = argv[1]
    out_path = argv[2] if len(argv) > 2 else None

    try:
        payload = decode_link(link)
        cfg = find_awg_section(payload)
        text = build_conf(cfg)
    except (ValueError, KeyError, TypeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    if out_path:
        # Создаём с правами 600 — приватный ключ
        fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(text)
        print(f"Записано: {out_path}", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
