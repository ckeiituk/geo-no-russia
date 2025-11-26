# 🌐 geo-no-russia

[![Build Status](https://github.com/ckeiituk/geo-no-russia/actions/workflows/build.yml/badge.svg)](https://github.com/ckeiituk/geo-no-russia/actions)
[![Latest Release](https://img.shields.io/github/v/release/ckeiituk/geo-no-russia)](https://github.com/ckeiituk/geo-no-russia/releases/latest)
[![License](https://img.shields.io/github/license/ckeiituk/geo-no-russia)](LICENSE)

Автоматически обновляемый geosite-список доменов, ограничивающих доступ с российских IP-адресов. Предназначен для маршрутизации в Xray/V2Ray/Sing-box.

Источник: [dartraiden/no-russia-hosts](https://github.com/dartraiden/no-russia-hosts)

## ✨ Особенности

- **Daily Updates**: Сборка запускается ежедневно в 01:30 MSK (22:30 UTC)
- **Zero Downtime**: Скрипты обновления поддерживают graceful reload без разрыва соединений
- **Integrity Check**: Каждый релиз включает SHA256-хеш для верификации целостности
- **Optimized**: Файл очищен от комментариев и дублей, готов к использованию

## 🚀 Быстрый старт

### Установка

```bash
curl -fsSL -o /usr/local/share/xray/geo-no-russia.dat \
  https://github.com/ckeiituk/geo-no-russia/releases/latest/download/geo-no-russia.dat
```

### Docker Compose

Добавьте volume в `docker-compose.yml`:

```yaml
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    volumes:
      - ./geo-no-russia.dat:/usr/local/share/xray/geo-no-russia.dat:ro
      - ./config.json:/etc/xray/config.json
```

### Конфигурация Xray

Добавьте правило маршрутизации в `config.json`:

```json
{
  "routing": {
    "rules": [
      {
        "type": "field",
        "domain": [
          "ext:geo-no-russia.dat:no-russia"
        ],
        "outboundTag": "proxy"
      }
    ]
  }
}
```

Где `"proxy"` — имя вашего outbound для зарубежного трафика.

## 🔄 Автообновление

### Скрипт с graceful reload

Создайте `/usr/local/bin/update-geo-no-russia.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Configuration
REPO="ckeiituk/geo-no-russia"
OUT_FILE="/opt/remnanode/geo-no-russia.dat"
CONTAINER_NAME="xray"

TMP_FILE="$OUT_FILE.tmp"

# Dependencies check
for cmd in curl jq docker sha256sum; do
  command -v $cmd >/dev/null || { echo "[!] Missing: $cmd"; exit 1; }
done

# Fetch latest release URL
RELEASE_URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | jq -r '.assets[] | select(.name=="geo-no-russia.dat") | .browser_download_url')

if [ -z "$RELEASE_URL" ] || [ "$RELEASE_URL" = "null" ]; then
  echo "[!] Failed to fetch release URL"
  exit 1
fi

# Download to temporary file
curl -fsSL "$RELEASE_URL" -o "$TMP_FILE"

# Compare hashes
OLD_HASH="NONE"
[ -f "$OUT_FILE" ] && OLD_HASH=$(sha256sum "$OUT_FILE" | awk '{print $1}')
NEW_HASH=$(sha256sum "$TMP_FILE" | awk '{print $1}')

if [ "$OLD_HASH" = "$NEW_HASH" ]; then
  echo "[=] No changes ($NEW_HASH)"
  rm -f "$TMP_FILE"
  exit 0
fi

# Update file
mv -f "$TMP_FILE" "$OUT_FILE"
echo "[+] Updated: $OLD_HASH -> $NEW_HASH"

# Graceful reload (SIGHUP) — no connection drops
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "[*] Reloading $CONTAINER_NAME..."
  docker exec "$CONTAINER_NAME" kill -HUP 1
  echo "[✓] Reload complete"
else
  echo "[!] Container $CONTAINER_NAME not running"
fi
```

Дайте права на выполнение:

```bash
chmod +x /usr/local/bin/update-geo-no-russia.sh
```

### Systemd timer

Создайте `/etc/systemd/system/geo-update.service`:

```ini
[Unit]
Description=Update geo-no-russia database
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-geo-no-russia.sh
```

Создайте `/etc/systemd/system/geo-update.timer`:

```ini
[Unit]
Description=Daily update for geo-no-russia.dat

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Активируйте:

```bash
systemctl daemon-reload
systemctl enable --now geo-update.timer
```

### Проверка работы таймера

```bash
# Статус таймера
systemctl status geo-update.timer

# Следующий запуск
systemctl list-timers geo-update.timer

# Ручной запуск
systemctl start geo-update.service

# Логи
journalctl -u geo-update.service -n 50
```

## 🔍 Верификация файла

Проверка SHA256-хеша:

```bash
cd /usr/local/share/xray
curl -fsSL https://github.com/ckeiituk/geo-no-russia/releases/latest/download/geo-no-russia.dat.sha256 \
  | sha256sum -c -
```

Ожидаемый вывод:
```
geo-no-russia.dat: OK
```

## 📊 Статистика

Посмотреть количество доменов в базе:

```bash
strings geo-no-russia.dat | grep -c '^[a-z]'
```

## ⚖️ Лицензия

MIT License. Исходные списки доменов принадлежат их авторам.

## 🙏 Благодарности

- [dartraiden/no-russia-hosts](https://github.com/dartraiden/no-russia-hosts) — источник списка доменов
- [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community) — инструмент компиляции
