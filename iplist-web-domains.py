#!/usr/bin/env python3
"""
VPN Gateway Web Interface v2.0
Управление списком доменов для VPN маршрутизации + GeoHide DNS
"""

from flask import Flask, request, render_template_string, redirect, jsonify
import subprocess
import os
import re
import json
import time
from datetime import datetime

# Конфигурация
DOMAINS_FILE = "/opt/vpn-gateway/vpn-domains.txt"
GEOHIDE_FILE = "/opt/vpn-gateway/geohide-hosts.txt"
CUSTOM_HOSTS_FILE = "/opt/vpn-gateway/custom-hosts.txt"
DNSMASQ_CONF_DIR = "/etc/dnsmasq.d/domains.d"
LOG_FILE = "/var/log/vpn-gateway-web.log"

# Capture session — анализ DNS-запросов клиента для поиска связанных доменов
CAPTURE_STATE_FILE = "/opt/vpn-gateway/capture-state.json"
DNSMASQ_QUERY_LOG = "/var/log/dnsmasq-queries.log"

# Сетевые параметры читаем из /etc/vpn-split/config.env (создаёт install.sh).
# Парсим вручную — формат простой KEY=VALUE.
VPN_SPLIT_CONFIG = "/etc/vpn-split/config.env"


def load_vpn_split_config():
    cfg = {
        "WAN_IF": "eth0",
        "LAN_IF": "eth1",
        "VPN_IF": "awg0",
        "LAN_NET": "192.168.1.0/24",
        "LAN_IP": "192.168.1.1/24",
    }
    if os.path.exists(VPN_SPLIT_CONFIG):
        with open(VPN_SPLIT_CONFIG) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip().strip('"').strip("'")
    return cfg


VPN_CONFIG = load_vpn_split_config()
VPN_INTERFACE = VPN_CONFIG["VPN_IF"]
LAN_IP_PLAIN = VPN_CONFIG["LAN_IP"].split("/", 1)[0]
LAN_NET_PREFIX = VPN_CONFIG["LAN_NET"].split("/", 1)[0].rsplit(".", 1)[0]
AWG_SERVICE = f"awg-quick@{VPN_INTERFACE}.service"

app = Flask(__name__)

# HTML шаблон с современным дизайном
HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>VPN Gateway</title>
    <style>
        :root {
            --bg-primary: #0f0f23;
            --bg-secondary: #1a1a2e;
            --bg-card: #16213e;
            --accent: #00d4ff;
            --accent-hover: #00a8cc;
            --success: #00ff88;
            --warning: #ffaa00;
            --error: #ff4757;
            --purple: #a855f7;
            --text: #e8e8e8;
            --text-muted: #8892b0;
        }
        
        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, var(--bg-primary) 0%, var(--bg-secondary) 100%);
            color: var(--text);
            min-height: 100vh;
            padding: 20px;
        }
        
        .container {
            max-width: 1000px;
            margin: 0 auto;
        }
        
        header {
            text-align: center;
            margin-bottom: 30px;
        }
        
        h1 {
            font-size: 2.5em;
            background: linear-gradient(90deg, var(--accent), var(--success));
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            margin-bottom: 10px;
        }
        
        .tabs {
            display: flex;
            gap: 10px;
            margin-bottom: 20px;
            flex-wrap: wrap;
            justify-content: center;
        }
        
        .tab-btn {
            padding: 12px 25px;
            border: 2px solid var(--accent);
            border-radius: 25px;
            background: transparent;
            color: var(--accent);
            cursor: pointer;
            font-size: 14px;
            font-weight: 600;
            transition: all 0.3s;
        }
        
        .tab-btn:hover, .tab-btn.active {
            background: var(--accent);
            color: var(--bg-primary);
        }
        
        .tab-btn.geohide {
            border-color: var(--purple);
            color: var(--purple);
        }
        
        .tab-btn.geohide:hover, .tab-btn.geohide.active {
            background: var(--purple);
            color: white;
        }
        
        .status-bar {
            display: flex;
            justify-content: center;
            gap: 20px;
            margin-bottom: 30px;
            flex-wrap: wrap;
        }
        
        .status-item {
            display: flex;
            align-items: center;
            gap: 8px;
            padding: 10px 20px;
            background: var(--bg-card);
            border-radius: 25px;
            border: 1px solid rgba(255,255,255,0.1);
            font-size: 14px;
        }
        
        .status-dot {
            width: 10px;
            height: 10px;
            border-radius: 50%;
            animation: pulse 2s infinite;
        }
        
        .status-dot.online { background: var(--success); }
        .status-dot.offline { background: var(--error); }
        
        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.5; }
        }
        
        .card {
            background: var(--bg-card);
            border-radius: 15px;
            padding: 25px;
            margin-bottom: 20px;
            border: 1px solid rgba(255,255,255,0.1);
            box-shadow: 0 10px 40px rgba(0,0,0,0.3);
        }
        
        .card h2 {
            color: var(--accent);
            margin-bottom: 20px;
            font-size: 1.3em;
            display: flex;
            align-items: center;
            gap: 10px;
        }
        
        .card h2.geohide {
            color: var(--purple);
        }
        
        .add-form {
            display: flex;
            gap: 10px;
            margin-bottom: 20px;
        }
        
        input[type="text"] {
            flex: 1;
            padding: 12px 20px;
            border: 2px solid rgba(255,255,255,0.1);
            border-radius: 10px;
            background: var(--bg-secondary);
            color: var(--text);
            font-size: 16px;
            transition: border-color 0.3s;
        }
        
        input[type="text"]:focus {
            outline: none;
            border-color: var(--accent);
        }
        
        textarea {
            width: 100%;
            min-height: 300px;
            padding: 15px;
            border: 2px solid rgba(255,255,255,0.1);
            border-radius: 10px;
            background: var(--bg-secondary);
            color: var(--text);
            font-family: 'Consolas', 'Monaco', monospace;
            font-size: 13px;
            line-height: 1.5;
            resize: vertical;
        }
        
        textarea:focus {
            outline: none;
            border-color: var(--accent);
        }
        
        button {
            padding: 12px 25px;
            border: none;
            border-radius: 10px;
            font-size: 14px;
            cursor: pointer;
            transition: all 0.3s;
            font-weight: 600;
        }
        
        .btn-primary {
            background: linear-gradient(135deg, var(--accent), var(--accent-hover));
            color: var(--bg-primary);
        }
        
        .btn-primary:hover {
            transform: translateY(-2px);
            box-shadow: 0 5px 20px rgba(0, 212, 255, 0.4);
        }
        
        .btn-danger {
            background: var(--error);
            color: white;
            padding: 8px 15px;
            font-size: 14px;
        }
        
        .btn-danger:hover {
            background: #ff6b7a;
        }
        
        .btn-warning {
            background: var(--warning);
            color: var(--bg-primary);
        }
        
        .btn-purple {
            background: linear-gradient(135deg, var(--purple), #9333ea);
            color: white;
        }
        
        .btn-purple:hover {
            transform: translateY(-2px);
            box-shadow: 0 5px 20px rgba(168, 85, 247, 0.4);
        }
        
        .btn-success {
            background: var(--success);
            color: var(--bg-primary);
        }
        
        .domains-list {
            max-height: 350px;
            overflow-y: auto;
        }
        
        .domain-item {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 12px 15px;
            background: var(--bg-secondary);
            border-radius: 8px;
            margin-bottom: 8px;
            transition: background 0.3s;
        }
        
        .domain-item:hover {
            background: rgba(0, 212, 255, 0.1);
        }
        
        .domain-name {
            font-family: 'Consolas', monospace;
            font-size: 14px;
        }
        
        .message {
            padding: 15px 20px;
            border-radius: 10px;
            margin-bottom: 20px;
            display: flex;
            align-items: center;
            gap: 10px;
        }
        
        .message.success {
            background: rgba(0, 255, 136, 0.1);
            border: 1px solid var(--success);
            color: var(--success);
        }
        
        .message.error {
            background: rgba(255, 71, 87, 0.1);
            border: 1px solid var(--error);
            color: var(--error);
        }
        
        .zone-info {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin-top: 15px;
        }
        
        .zone-card {
            padding: 15px;
            border-radius: 10px;
            text-align: center;
        }
        
        .zone-card.vpn { background: rgba(0, 212, 255, 0.1); border: 1px solid var(--accent); }
        .zone-card.bypass { background: rgba(255, 170, 0, 0.1); border: 1px solid var(--warning); }
        .zone-card.split { background: rgba(0, 255, 136, 0.1); border: 1px solid var(--success); }
        
        .zone-card h3 {
            font-size: 14px;
            margin-bottom: 5px;
        }
        
        .zone-card .range {
            font-family: 'Consolas', monospace;
            font-size: 13px;
            color: var(--text-muted);
        }
        
        .tab-content {
            display: none;
        }
        
        .tab-content.active {
            display: block;
        }
        
        .stats-row {
            display: flex;
            gap: 20px;
            margin-bottom: 20px;
            flex-wrap: wrap;
        }
        
        .stat-box {
            flex: 1;
            min-width: 150px;
            padding: 15px;
            background: var(--bg-secondary);
            border-radius: 10px;
            text-align: center;
        }
        
        .stat-box .number {
            font-size: 2em;
            font-weight: bold;
            color: var(--purple);
        }
        
        .stat-box .label {
            color: var(--text-muted);
            font-size: 12px;
        }
        
        .btn-row {
            display: flex;
            gap: 10px;
            margin-top: 15px;
            flex-wrap: wrap;
        }
        
        .info-box {
            background: rgba(168, 85, 247, 0.1);
            border: 1px solid var(--purple);
            border-radius: 10px;
            padding: 15px;
            margin-bottom: 20px;
            font-size: 13px;
            color: var(--text-muted);
        }
        
        footer {
            text-align: center;
            margin-top: 30px;
            color: var(--text-muted);
            font-size: 14px;
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>&#x1F6E1;&#xFE0F; VPN Gateway</h1>
            <p style="color: var(--text-muted);">Управление маршрутизацией и DNS</p>
        </header>
        
        <div class="status-bar">
            <div class="status-item">
                <div class="status-dot {{ 'online' if vpn_status else 'offline' }}"></div>
                <span>VPN {{ 'Online' if vpn_status else 'Offline' }}</span>
            </div>
            <div class="status-item">
                <span>&#x1F4CA; Доменов: {{ domain_count }}</span>
            </div>
            <div class="status-item">
                <span>&#x1F310; IP в ipset: {{ ipset_count }}</span>
            </div>
            <div class="status-item">
                <span>&#x1F4DD; GeoHide: {{ geohide_count }} записей</span>
            </div>
        </div>
        
        {% if message %}
        <div class="message {{ message_type }}">
            {{ message }}
        </div>
        {% endif %}
        
        <div class="tabs">
            <button class="tab-btn active" onclick="showTab('domains')">&#x1F4CB; VPN Домены</button>
            <button class="tab-btn geohide" onclick="showTab('geohide')">&#x1F4DD; GeoHide DNS</button>
            <button class="tab-btn" onclick="showTab('capture')">&#x1F50E; Запись связей</button>
            <button class="tab-btn" onclick="showTab('zones')">&#x1F4E1; Зоны</button>
        </div>
        
        <!-- VPN Domains Tab -->
        <div id="domains-tab" class="tab-content active">
            <div class="card">
                <h2>&#x2795; Добавить домен</h2>
                <form method="POST" action="/add" class="add-form">
                    <input type="text" name="domain" placeholder="example.com или *.google.com" required>
                    <button type="submit" class="btn-primary">Добавить</button>
                </form>
                <p style="color: var(--text-muted); font-size: 13px;">
                    &#x1F4A1; Домены из этого списка будут маршрутизироваться через VPN (для Split зоны).
                </p>
            </div>
            
            <div class="card">
                <h2>&#x1F4CB; Список доменов для VPN</h2>
                <div class="domains-list">
                    {% if domains %}
                        {% for domain in domains %}
                        <div class="domain-item">
                            <span class="domain-name">{{ domain }}</span>
                            <form method="POST" action="/delete" style="display: inline;">
                                <input type="hidden" name="domain" value="{{ domain }}">
                                <button type="submit" class="btn-danger">&#x2715;</button>
                            </form>
                        </div>
                        {% endfor %}
                    {% else %}
                        <p style="color: var(--text-muted); text-align: center; padding: 20px;">
                            Список пуст. Добавьте домены для маршрутизации через VPN.
                        </p>
                    {% endif %}
                </div>
            </div>
        </div>
        
        <!-- GeoHide DNS Tab -->
        <div id="geohide-tab" class="tab-content">
            <div class="info-box">
                &#x1F4DD; <strong>GeoHide DNS</strong> — подмена DNS для обхода геоблокировки. 
                Работает для VPN и Split зон. Bypass зона использует обычный DNS.
                <br>Автообновление: ежедневно в 4:00
            </div>
            
            <div class="stats-row">
                <div class="stat-box">
                    <div class="number">{{ geohide_count }}</div>
                    <div class="label">GeoHide записей</div>
                </div>
                <div class="stat-box">
                    <div class="number">{{ custom_hosts_count }}</div>
                    <div class="label">Custom записей</div>
                </div>
                <div class="stat-box">
                    <div class="number">{{ geohide_last_update }}</div>
                    <div class="label">Последнее обновление</div>
                </div>
            </div>
            
            <div class="card">
                <h2 class="geohide">&#x1F4E5; GeoHide Hosts (авто-обновляется)</h2>
                <form method="POST" action="/save-geohide">
                    <textarea name="content">{{ geohide_content }}</textarea>
                    <div class="btn-row">
                        <button type="submit" class="btn-purple">&#x1F4BE; Сохранить изменения</button>
                        <button type="button" class="btn-warning" onclick="if(confirm('Скачать заново? Ваши правки будут перезаписаны.')) document.getElementById('update-form').submit();">&#x1F504; Обновить из GitHub</button>
                    </div>
                </form>
                <form id="update-form" method="POST" action="/update-geohide" style="display: none;"></form>
            </div>
            
            <div class="card">
                <h2 class="geohide">&#x270F;&#xFE0F; Custom Hosts (ваши записи)</h2>
                <form method="POST" action="/save-custom-hosts">
                    <textarea name="content">{{ custom_hosts_content }}</textarea>
                    <div class="btn-row">
                        <button type="submit" class="btn-purple">&#x1F4BE; Сохранить</button>
                    </div>
                </form>
                <p style="color: var(--text-muted); font-size: 12px; margin-top: 10px;">
                    Формат: IP DOMAIN (по одной записи на строку). Этот файл НЕ перезаписывается при автообновлении.
                </p>
            </div>
        </div>
        
        <!-- Capture Tab -->
        <div id="capture-tab" class="tab-content">
            <div class="info-box">
                &#x1F50E; <strong>Запись связей</strong> — найти все домены, к которым обращается приложение/сайт,
                чтобы целиком завести его в VPN. Нажмите «Старт», воспроизведите трафик на клиенте,
                нажмите «Стоп» — увидите список запрошенных доменов с галочками для добавления.
            </div>

            <div class="card">
                <h2>&#x23FA;&#xFE0F; Управление записью</h2>
                <div id="capture-controls">
                    <div id="capture-idle">
                        <label style="display: block; margin-bottom: 8px;">Фильтр по клиенту (опционально):</label>
                        <select id="capture-client" style="width: 100%; padding: 10px; border-radius: 8px; background: var(--bg-secondary); color: var(--text); border: 1px solid var(--accent); margin-bottom: 12px;">
                            <option value="">Все клиенты сети</option>
                        </select>
                        <button onclick="captureStart()" class="btn-primary">&#x25B6;&#xFE0F; Старт записи</button>
                    </div>
                    <div id="capture-active" style="display: none;">
                        <p style="margin-bottom: 12px;">
                            &#x1F534; <strong>Идёт запись...</strong> <span id="capture-elapsed">0с</span>
                            <span id="capture-client-info" style="color: var(--text-muted);"></span>
                        </p>
                        <p style="color: var(--text-muted); font-size: 13px; margin-bottom: 12px;">
                            Откройте на клиенте нужное приложение, дождитесь его загрузки, потом нажмите «Стоп».
                        </p>
                        <button onclick="captureStop()" class="btn-warning">&#x23F9;&#xFE0F; Стоп и проанализировать</button>
                    </div>
                </div>
            </div>

            <div id="capture-result" class="card" style="display: none;">
                <h2>&#x1F4DD; Результат записи</h2>
                <p id="capture-summary" style="color: var(--text-muted); margin-bottom: 12px;"></p>
                <div style="margin-bottom: 12px;">
                    <button onclick="captureSelectNew()" class="btn-primary" style="margin-right: 8px;">Выбрать только новые</button>
                    <button onclick="captureSelectAll()" class="btn-primary" style="margin-right: 8px; background: var(--bg-card);">Выбрать все</button>
                    <button onclick="captureClearSelection()" class="btn-primary" style="background: var(--bg-card);">Снять</button>
                </div>
                <div id="capture-list" style="max-height: 500px; overflow-y: auto; margin-bottom: 12px;"></div>
                <button onclick="captureAdd()" class="btn-primary">&#x2795; Добавить отмеченные в VPN-список</button>
            </div>
        </div>

        <!-- Zones Tab -->
        <div id="zones-tab" class="tab-content">
            <div class="card">
                <h2>&#x1F4E1; Зоны маршрутизации</h2>
                <div class="zone-info">
                    <div class="zone-card vpn">
                        <h3>&#x1F512; VPN Zone</h3>
                        <div class="range">{{ lan_prefix }}.20-30</div>
                        <small>Весь трафик через VPN</small>
                    </div>
                    <div class="zone-card bypass">
                        <h3>&#x1F680; Bypass Zone</h3>
                        <div class="range">{{ lan_prefix }}.31-49</div>
                        <small>Прямое подключение</small>
                    </div>
                    <div class="zone-card split">
                        <h3>&#x26A1; Split Zone</h3>
                        <div class="range">Остальные IP</div>
                        <small>По доменам</small>
                    </div>
                </div>
            </div>
            
            <div class="card" style="text-align: center;">
                <form method="POST" action="/restart" style="display: inline;">
                    <button type="submit" class="btn-warning">&#x1F504; Перезапустить VPN</button>
                </form>
            </div>
        </div>
        
        <footer>
            VPN Gateway v2.0 | {{ last_update }}
        </footer>
    </div>
    
    <script>
        function showTab(tabName) {
            // Hide all tabs
            document.querySelectorAll('.tab-content').forEach(tab => {
                tab.classList.remove('active');
            });
            document.querySelectorAll('.tab-btn').forEach(btn => {
                btn.classList.remove('active');
            });

            // Show selected tab
            document.getElementById(tabName + '-tab').classList.add('active');
            event.target.classList.add('active');

            if (tabName === 'capture') captureRefreshStatus();
        }

        let captureTimer = null;
        let captureItems = [];

        async function captureRefreshStatus() {
            const r = await fetch('/capture/status');
            const data = await r.json();

            // Заполняем список клиентов из DHCP-leases
            const sel = document.getElementById('capture-client');
            const cur = sel.value;
            sel.innerHTML = '<option value="">Все клиенты сети</option>';
            (data.leases || []).forEach(([ip, host]) => {
                const opt = document.createElement('option');
                opt.value = ip;
                opt.textContent = host ? ip + ' — ' + host : ip;
                sel.appendChild(opt);
            });
            sel.value = cur;

            if (data.running) {
                document.getElementById('capture-idle').style.display = 'none';
                document.getElementById('capture-active').style.display = 'block';
                const startedAt = data.state.started_unix;
                document.getElementById('capture-client-info').textContent =
                    data.state.client_ip ? '(только ' + data.state.client_ip + ')' : '(все клиенты)';
                if (captureTimer) clearInterval(captureTimer);
                captureTimer = setInterval(() => {
                    const elapsed = Math.floor(Date.now() / 1000 - startedAt);
                    document.getElementById('capture-elapsed').textContent = elapsed + 'с';
                }, 1000);
            } else {
                document.getElementById('capture-idle').style.display = 'block';
                document.getElementById('capture-active').style.display = 'none';
                if (captureTimer) { clearInterval(captureTimer); captureTimer = null; }
            }
        }

        async function captureStart() {
            const client = document.getElementById('capture-client').value;
            const fd = new FormData();
            if (client) fd.append('client_ip', client);
            const r = await fetch('/capture/start', { method: 'POST', body: fd });
            const data = await r.json();
            if (!data.ok) { alert(data.error || 'Ошибка'); return; }
            document.getElementById('capture-result').style.display = 'none';
            captureRefreshStatus();
        }

        async function captureStop() {
            const r = await fetch('/capture/stop', { method: 'POST' });
            const data = await r.json();
            if (!data.ok) { alert(data.error || 'Ошибка'); captureRefreshStatus(); return; }
            captureItems = data.items;
            renderCaptureList(data);
            captureRefreshStatus();
        }

        function renderCaptureList(data) {
            document.getElementById('capture-result').style.display = 'block';
            document.getElementById('capture-summary').textContent =
                `Длительность: ${data.duration_sec}с · Найдено доменов: ${data.total} (новых: ${data.new_count})` +
                (data.client_ip ? ` · Клиент: ${data.client_ip}` : '');
            const list = document.getElementById('capture-list');
            list.innerHTML = '';
            if (data.items.length === 0) {
                list.innerHTML = '<p style="color: var(--text-muted); text-align: center; padding: 20px;">Запросов не зафиксировано — возможно клиент использовал кэшированные ответы или DNS-over-HTTPS.</p>';
                return;
            }
            data.items.forEach((item, idx) => {
                const row = document.createElement('div');
                row.className = 'domain-item';
                row.style.opacity = item.covered ? '0.5' : '1';
                const tag = item.covered ?
                    '<span style="color: var(--success); font-size: 12px; margin-left: 8px;">✓ уже в списке</span>' :
                    '<span style="color: var(--warning); font-size: 12px; margin-left: 8px;">★ новый</span>';
                row.innerHTML = `
                    <label style="display: flex; align-items: center; gap: 10px; flex: 1; cursor: pointer;">
                        <input type="checkbox" data-idx="${idx}" ${item.covered ? '' : 'checked'}>
                        <span class="domain-name" style="flex: 1;">${item.domain}</span>
                        <span style="color: var(--text-muted); font-size: 12px;">${item.count}×</span>
                        <span style="color: var(--text-muted); font-size: 11px;">${item.client}</span>
                        ${tag}
                    </label>
                `;
                list.appendChild(row);
            });
        }

        function captureSelectNew() {
            document.querySelectorAll('#capture-list input[type=checkbox]').forEach(cb => {
                const idx = parseInt(cb.dataset.idx);
                cb.checked = !captureItems[idx].covered;
            });
        }
        function captureSelectAll() {
            document.querySelectorAll('#capture-list input[type=checkbox]').forEach(cb => cb.checked = true);
        }
        function captureClearSelection() {
            document.querySelectorAll('#capture-list input[type=checkbox]').forEach(cb => cb.checked = false);
        }

        async function captureAdd() {
            const selected = [];
            document.querySelectorAll('#capture-list input[type=checkbox]:checked').forEach(cb => {
                const idx = parseInt(cb.dataset.idx);
                selected.push(captureItems[idx].domain);
            });
            if (selected.length === 0) { alert('Не выбрано ни одного домена'); return; }
            const fd = new FormData();
            fd.append('domains', selected.join(','));
            const r = await fetch('/capture/add', { method: 'POST', body: fd });
            const data = await r.json();
            if (!data.ok) { alert(data.error || 'Ошибка'); return; }
            alert(`Добавлено: ${data.added.length}\nПропущено (уже есть): ${data.skipped.length}\nОтклонено (невалидный формат): ${data.invalid.length}`);
            // Перезагрузим страницу чтобы обновить вкладку Доменов
            if (data.added.length > 0) location.reload();
        }
    </script>
</body>
</html>
"""

def log(message):
    """Логирование в файл"""
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    with open(LOG_FILE, 'a') as f:
        f.write(f"[{timestamp}] {message}\n")

def ensure_files_exist():
    """Создаёт необходимые файлы и директории"""
    os.makedirs(DNSMASQ_CONF_DIR, exist_ok=True)
    os.makedirs(os.path.dirname(DOMAINS_FILE), exist_ok=True)
    
    for filepath in [DOMAINS_FILE, GEOHIDE_FILE, CUSTOM_HOSTS_FILE]:
        if not os.path.exists(filepath):
            with open(filepath, 'w') as f:
                f.write("")

def load_domains():
    """Загружает список доменов"""
    ensure_files_exist()
    domains = []
    with open(DOMAINS_FILE, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                domains.append(line)
    return sorted(set(domains))

def save_domains(domains):
    """Сохраняет список доменов"""
    with open(DOMAINS_FILE, 'w') as f:
        f.write("# VPN Gateway - Domain List\n")
        f.write("# Автоматически генерируется веб-интерфейсом\n\n")
        for domain in sorted(set(domains)):
            f.write(f"{domain}\n")

def update_dnsmasq():
    """Обновляет конфигурацию dnsmasq для ipset"""
    domains = load_domains()
    
    conf_file = os.path.join(DNSMASQ_CONF_DIR, "vpn-domains.conf")
    with open(conf_file, 'w') as f:
        f.write("# Auto-generated by VPN Gateway Web UI\n")
        f.write("# DO NOT EDIT MANUALLY\n\n")
        for domain in domains:
            f.write(f"ipset=/{domain}/vpn_domains\n")
    
    try:
        subprocess.run(['systemctl', 'reload', 'dnsmasq'], check=False)
    except:
        pass
    
    log(f"Updated dnsmasq config with {len(domains)} domains")

def get_vpn_status():
    """Проверяет статус VPN"""
    try:
        result = subprocess.run(['ip', 'link', 'show', VPN_INTERFACE], 
                              capture_output=True, timeout=5)
        return result.returncode == 0
    except:
        return False

def get_ipset_count():
    """Получает количество IP в ipset"""
    try:
        result = subprocess.run(['ipset', 'list', 'vpn_domains', '-terse'],
                              capture_output=True, text=True, timeout=5)
        for line in result.stdout.split('\n'):
            if 'Number of entries' in line:
                return int(line.split(':')[1].strip())
    except:
        pass
    return 0

def get_hosts_count(filepath):
    """Получает количество записей в hosts файле"""
    try:
        if os.path.exists(filepath):
            with open(filepath, 'r') as f:
                count = sum(1 for line in f if line.strip() and not line.startswith('#') and re.match(r'^\d+\.', line))
                return count
    except:
        pass
    return 0

def get_file_content(filepath):
    """Читает содержимое файла"""
    try:
        if os.path.exists(filepath):
            with open(filepath, 'r') as f:
                return f.read()
    except:
        pass
    return ""

def get_file_mtime(filepath):
    """Получает время модификации файла"""
    try:
        if os.path.exists(filepath):
            mtime = os.path.getmtime(filepath)
            return datetime.fromtimestamp(mtime).strftime('%d.%m %H:%M')
    except:
        pass
    return "—"

def is_valid_domain(domain):
    """Проверяет валидность домена"""
    check_domain = domain.lstrip('*.')
    pattern = r'^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$'
    return bool(re.match(pattern, check_domain))


# ===== Capture session: запись связанных доменов через лог dnsmasq =====

def load_capture_state():
    """Возвращает текущее состояние записи или None."""
    if not os.path.exists(CAPTURE_STATE_FILE):
        return None
    try:
        with open(CAPTURE_STATE_FILE, 'r') as f:
            return json.load(f)
    except Exception:
        return None

def save_capture_state(state):
    with open(CAPTURE_STATE_FILE, 'w') as f:
        json.dump(state, f)

def clear_capture_state():
    if os.path.exists(CAPTURE_STATE_FILE):
        os.remove(CAPTURE_STATE_FILE)

# Регэксп строки запроса dnsmasq:
# "<datetime> dnsmasq[<pid>]: query[A] <domain> from <client_ip>"
# либо без префикса (если log-facility пишет свой формат) — оба варианта.
QUERY_RE = re.compile(
    r'query\[(?:A|AAAA|HTTPS)\]\s+(?P<domain>\S+)\s+from\s+(?P<client>\d+\.\d+\.\d+\.\d+)'
)

def parse_query_log(start_offset, client_filter=None):
    """Читает dnsmasq query log с указанной байтовой позиции, возвращает {domain: {count, last_client}}."""
    domains = {}
    if not os.path.exists(DNSMASQ_QUERY_LOG):
        return domains, 0
    end_offset = os.path.getsize(DNSMASQ_QUERY_LOG)
    if end_offset < start_offset:
        # Лог ротировался — читаем с начала
        start_offset = 0
    try:
        with open(DNSMASQ_QUERY_LOG, 'rb') as f:
            f.seek(start_offset)
            chunk = f.read()
    except Exception as e:
        log(f"capture parse error: {e}")
        return domains, end_offset
    text = chunk.decode('utf-8', errors='replace')
    for line in text.splitlines():
        m = QUERY_RE.search(line)
        if not m:
            continue
        client = m.group('client')
        if client_filter and client != client_filter:
            continue
        domain = m.group('domain').lower().rstrip('.')
        # Игнорируем PTR (in-addr.arpa) и DNSSEC технические запросы
        if domain.endswith('.arpa') or domain.endswith('.local'):
            continue
        entry = domains.setdefault(domain, {'count': 0, 'client': client})
        entry['count'] += 1
        entry['client'] = client
    return domains, end_offset

def domain_already_covered(domain, vpn_list):
    """True если domain уже покрыт списком vpn (exact или wildcard)."""
    d = domain.lower()
    for entry in vpn_list:
        e = entry.lower()
        if e.startswith('*.'):
            suffix = e[2:]
            if d == suffix or d.endswith('.' + suffix):
                return True
        elif e == d:
            return True
    return False

def get_dhcp_leases():
    """Возвращает список (ip, hostname) активных DHCP-lease'ов."""
    leases = []
    path = '/var/lib/dhcp/dhcpd.leases'
    if not os.path.exists(path):
        return leases
    try:
        with open(path, 'r') as f:
            content = f.read()
    except Exception:
        return leases
    # Простая разбивка по lease-блокам
    block_re = re.compile(r'lease\s+(\d+\.\d+\.\d+\.\d+)\s*\{([^}]+)\}', re.DOTALL)
    seen = {}
    for m in block_re.finditer(content):
        ip = m.group(1)
        body = m.group(2)
        if 'binding state active' not in body:
            continue
        host_m = re.search(r'client-hostname\s+"([^"]+)"', body)
        host = host_m.group(1) if host_m else ''
        seen[ip] = host  # перезаписываем — последний в файле = самый свежий
    return [(ip, host) for ip, host in sorted(seen.items())]

@app.route('/capture/start', methods=['POST'])
def capture_start():
    if load_capture_state():
        return jsonify({'ok': False, 'error': 'Запись уже идёт'}), 400
    client_ip = (request.form.get('client_ip') or '').strip() or None
    log_offset = os.path.getsize(DNSMASQ_QUERY_LOG) if os.path.exists(DNSMASQ_QUERY_LOG) else 0
    state = {
        'started_unix': int(time.time()),
        'started_at': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        'log_offset': log_offset,
        'client_ip': client_ip,
    }
    save_capture_state(state)
    log(f"Capture started: client={client_ip or 'all'}, offset={log_offset}")
    return jsonify({'ok': True, 'state': state})

@app.route('/capture/status', methods=['GET'])
def capture_status():
    state = load_capture_state()
    return jsonify({
        'running': bool(state),
        'state': state,
        'leases': get_dhcp_leases(),
    })

@app.route('/capture/stop', methods=['POST'])
def capture_stop():
    state = load_capture_state()
    if not state:
        return jsonify({'ok': False, 'error': 'Нет активной записи'}), 400
    domains_seen, end_offset = parse_query_log(state['log_offset'], state.get('client_ip'))
    vpn_list = load_domains()

    # Сортировка: сначала "новые" (не покрытые), внутри — по убыванию count
    items = []
    for d, info in domains_seen.items():
        items.append({
            'domain': d,
            'count': info['count'],
            'client': info['client'],
            'covered': domain_already_covered(d, vpn_list),
        })
    items.sort(key=lambda x: (x['covered'], -x['count'], x['domain']))

    duration = int(time.time()) - state['started_unix']
    clear_capture_state()
    log(f"Capture stopped: {len(items)} unique domains, duration={duration}s")
    return jsonify({
        'ok': True,
        'duration_sec': duration,
        'client_ip': state.get('client_ip'),
        'total': len(items),
        'new_count': sum(1 for i in items if not i['covered']),
        'items': items,
    })

@app.route('/capture/add', methods=['POST'])
def capture_add():
    raw = request.form.get('domains', '')
    requested = [d.strip().lower() for d in raw.split(',') if d.strip()]
    if not requested:
        return jsonify({'ok': False, 'error': 'Нет доменов для добавления'}), 400

    domains = load_domains()
    added = []
    skipped = []
    invalid = []
    for d in requested:
        if not is_valid_domain(d):
            invalid.append(d)
            continue
        if domain_already_covered(d, domains):
            skipped.append(d)
            continue
        domains.append(d)
        added.append(d)
    if added:
        save_domains(domains)
        update_dnsmasq()
        log(f"Capture: added {len(added)} domains: {added}")
    return jsonify({
        'ok': True,
        'added': added,
        'skipped': skipped,
        'invalid': invalid,
    })

def redirect_with_message(message, msg_type):
    """Редирект с сообщением"""
    from urllib.parse import quote
    return redirect(f"/?message={quote(message)}&type={msg_type}")

@app.route('/', methods=['GET'])
def index():
    domains = load_domains()
    return render_template_string(
        HTML_TEMPLATE,
        domains=domains,
        domain_count=len(domains),
        vpn_status=get_vpn_status(),
        ipset_count=get_ipset_count(),
        geohide_count=get_hosts_count(GEOHIDE_FILE),
        custom_hosts_count=get_hosts_count(CUSTOM_HOSTS_FILE),
        geohide_content=get_file_content(GEOHIDE_FILE),
        custom_hosts_content=get_file_content(CUSTOM_HOSTS_FILE),
        geohide_last_update=get_file_mtime(GEOHIDE_FILE),
        lan_prefix=LAN_NET_PREFIX,
        message=request.args.get('message'),
        message_type=request.args.get('type', 'success'),
        last_update=datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    )

@app.route('/add', methods=['POST'])
def add_domain():
    domain = request.form.get('domain', '').strip().lower()
    
    if not domain:
        return redirect_with_message("Домен не указан", "error")
    
    if not is_valid_domain(domain):
        return redirect_with_message(f"Некорректный домен: {domain}", "error")
    
    domains = load_domains()
    if domain in domains:
        return redirect_with_message(f"Домен {domain} уже в списке", "error")
    
    domains.append(domain)
    save_domains(domains)
    update_dnsmasq()
    
    log(f"Added domain: {domain}")
    return redirect_with_message(f"✓ Добавлен: {domain}", "success")

@app.route('/delete', methods=['POST'])
def delete_domain():
    domain = request.form.get('domain', '').strip()
    
    domains = load_domains()
    if domain in domains:
        domains.remove(domain)
        save_domains(domains)
        update_dnsmasq()
        log(f"Deleted domain: {domain}")
        return redirect_with_message(f"✓ Удалён: {domain}", "success")
    
    return redirect_with_message(f"Домен не найден: {domain}", "error")

@app.route('/save-geohide', methods=['POST'])
def save_geohide():
    """Сохранение отредактированного GeoHide hosts"""
    content = request.form.get('content', '')
    try:
        with open(GEOHIDE_FILE, 'w') as f:
            f.write(content)
        subprocess.run(['systemctl', 'reload', 'dnsmasq'], check=False)
        log("GeoHide hosts saved via web UI")
        return redirect_with_message("✓ GeoHide hosts сохранён", "success")
    except Exception as e:
        return redirect_with_message(f"Ошибка: {str(e)}", "error")

@app.route('/save-custom-hosts', methods=['POST'])
def save_custom_hosts():
    """Сохранение пользовательского hosts"""
    content = request.form.get('content', '')
    try:
        with open(CUSTOM_HOSTS_FILE, 'w') as f:
            f.write(content)
        subprocess.run(['systemctl', 'reload', 'dnsmasq'], check=False)
        log("Custom hosts saved via web UI")
        return redirect_with_message("✓ Custom hosts сохранён", "success")
    except Exception as e:
        return redirect_with_message(f"Ошибка: {str(e)}", "error")

@app.route('/update-geohide', methods=['POST'])
def update_geohide():
    """Принудительное обновление GeoHide hosts из GitHub"""
    try:
        result = subprocess.run(['/usr/local/sbin/update-geohide.sh', '--force'],
                              capture_output=True, text=True, timeout=120)
        if result.returncode == 0:
            log("GeoHide hosts updated via web UI")
            return redirect_with_message("✓ GeoHide hosts обновлён из GitHub", "success")
        else:
            return redirect_with_message("Ошибка обновления: " + result.stderr[:100], "error")
    except Exception as e:
        return redirect_with_message(f"Ошибка: {str(e)}", "error")

@app.route('/restart', methods=['POST'])
def restart_vpn():
    """Перезапуск AmneziaWG туннеля (awg-quick@<iface>.service)."""
    try:
        subprocess.run(['systemctl', 'restart', AWG_SERVICE], check=False)
        log(f"VPN restart requested via web UI ({AWG_SERVICE})")
        return redirect_with_message("VPN перезапускается...", "success")
    except Exception as e:
        return redirect_with_message(f"Ошибка: {str(e)}", "error")

if __name__ == '__main__':
    ensure_files_exist()
    # Биндимся только на LAN — web-UI не должен торчать в WAN.
    app.run(host=LAN_IP_PLAIN, port=8080)
