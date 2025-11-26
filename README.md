# geo-no-russia

Автоматическая сборка `geo-no-russia.dat` для Xray/V2Ray из [dartraiden/no-russia-hosts](https://github.com/dartraiden/no-russia-hosts).

## О проекте

Список доменов, владельцы которых ограничивают доступ с российских IP-адресов, скомпилированный в формат `.dat` для использования в Xray/V2Ray routing.

### Особенности

- ✅ Автоматическое обновление каждую субботу в 23:30 (по времени +05)
- ✅ Релизы с SHA256 хэш-суммами для проверки целостности
- ✅ Источник: проверенный список [dartraiden/no-russia-hosts](https://github.com/dartraiden/no-russia-hosts)

## Установка

### 1. Скачивание

Скачайте последнюю версию:

```bash
curl -L -o geo-no-russia.dat \
  https://github.com/ckeiituk/geo-no-russia-clean/releases/latest/download/geo-no-russia.dat
```

### 2. Подключение в Xray

#### Docker Compose

Добавьте в `docker-compose.yml`:

```yaml
services:
  xray:
    volumes:
      - './geo-no-russia.dat:/usr/local/share/xray/geo-no-russia.dat:ro'
```

#### Конфигурация routing в `config.json`

Добавьте правило в `routing.rules`:

```json
{
  "type": "field",
  "domain": [
    "ext:geo-no-russia.dat:no-russia"
  ],
  "outboundTag": "proxy"
}
```

Где `"proxy"` — имя вашего outbound с зарубежным proxy/VPN.

### 3. Проверка

```bash
# Проверка конфигурации
docker exec xray xray -test -c /etc/xray/config.json

# Перезапуск
docker compose restart xray
```

## Автообновление (опционально)

Создайте скрипт `/usr/local/bin/update-geo-no-russia.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

OUT_FILE="/opt/xray/geo-no-russia.dat"
RELEASE_URL="https://github.com/ckeiituk/geo-no-russia-clean/releases/latest/download/geo-no-russia.dat"
COMPOSE_FILE="/opt/xray/docker-compose.yml"

old_hash="$([ -f "$OUT_FILE" ] && sha256sum "$OUT_FILE" | awk '{print $1}' || echo NONE)"
curl -fsSL "$RELEASE_URL" -o "$OUT_FILE.tmp"
new_hash="$(sha256sum "$OUT_FILE.tmp" | awk '{print $1}')"

if [ "$old_hash" = "$new_hash" ]; then
  echo "[✓] No changes ($new_hash)"
  rm "$OUT_FILE.tmp"
  exit 0
fi

mv "$OUT_FILE.tmp" "$OUT_FILE"
echo "[✓] Updated: $new_hash"
docker compose -f "$COMPOSE_FILE" restart xray
```

Выдайте права:

```bash
sudo chmod +x /usr/local/bin/update-geo-no-russia.sh
```

### systemd timer

```ini
# /etc/systemd/system/update-geo-no-russia.service
[Unit]
Description=Update geo-no-russia.dat
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-geo-no-russia.sh
```

```ini
# /etc/systemd/system/update-geo-no-russia.timer
[Unit]
Description=Weekly update of geo-no-russia.dat

[Timer]
OnCalendar=Sun 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Активируйте:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now update-geo-no-russia.timer
```

## Лицензия

MIT

## Благодарности

- [dartraiden/no-russia-hosts](https://github.com/dartraiden/no-russia-hosts) — источник списка доменов
- [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community) — инструмент сборки `.dat`
