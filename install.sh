#!/usr/bin/env bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[*]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }

# Check root
if [[ $EUID -ne 0 ]]; then
   log_error "Запустите скрипт с sudo"
   exit 1
fi

# Dependencies check
log_info "Проверка зависимостей..."
MISSING_DEPS=()
for cmd in curl jq sha256sum systemctl; do
  if ! command -v "$cmd" &>/dev/null; then
    MISSING_DEPS+=("$cmd")
  fi
done

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
  log_error "Отсутствуют: ${MISSING_DEPS[*]}"
  log_info "Установите: apt install ${MISSING_DEPS[*]}"
  exit 1
fi

if ! command -v docker &>/dev/null; then
  log_warn "docker не найден: автоперезагрузка контейнера работать не будет"
fi

if ! command -v strings &>/dev/null; then
  log_warn "strings не найден: количество доменов после загрузки показано не будет"
fi

# Interactive configuration
log_info "Конфигурация установки"
echo

read -p "Путь к geo-no-russia.dat [/opt/remnanode/geo-no-russia.dat]: " OUT_FILE </dev/tty
OUT_FILE=${OUT_FILE:-/opt/remnanode/geo-no-russia.dat}

read -p "Имя Docker контейнера Xray [remnanode]: " CONTAINER_NAME </dev/tty
CONTAINER_NAME=${CONTAINER_NAME:-remnanode}

read -p "Время обновления (формат HH:MM) [04:00]: " UPDATE_TIME </dev/tty
UPDATE_TIME=${UPDATE_TIME:-04:00}

# Validate time format (HH:MM, 24h)
if ! [[ $UPDATE_TIME =~ ^([0-9]{2}):([0-9]{2})$ ]]; then
  log_error "Неверный формат времени. Используйте HH:MM"
  exit 1
fi

HOUR=${BASH_REMATCH[1]}
MINUTE=${BASH_REMATCH[2]}
if ((10#$HOUR > 23 || 10#$MINUTE > 59)); then
  log_error "Неверное время. Часы 00-23, минуты 00-59"
  exit 1
fi

echo
log_info "Параметры установки:"
echo "  Файл: $OUT_FILE"
echo "  Контейнер: $CONTAINER_NAME"
echo "  Время обновления: $UPDATE_TIME"
echo

read -p "Продолжить? [Y/n]: " CONFIRM </dev/tty
CONFIRM=${CONFIRM:-Y}
if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
  log_warn "Установка отменена"
  exit 0
fi

# Create directory
OUT_DIR=$(dirname "$OUT_FILE")
if [[ ! -d "$OUT_DIR" ]]; then
  log_info "Создание директории $OUT_DIR"
  mkdir -p "$OUT_DIR"
fi

# Download initial file
log_info "Загрузка geo-no-russia.dat..."
DOWNLOAD_URL="https://github.com/ckeiituk/geo-no-russia/releases/latest/download/geo-no-russia.dat"
if curl -fsSL "$DOWNLOAD_URL" -o "$OUT_FILE"; then
  if command -v strings &>/dev/null; then
    DOMAINS=$(strings "$OUT_FILE" | grep -c '^[a-z]' || echo "unknown")
    log_success "Файл загружен ($DOMAINS доменов)"
  else
    log_success "Файл загружен"
  fi
else
  log_error "Не удалось загрузить файл"
  exit 1
fi

# Create update script
log_info "Создание скрипта обновления..."
ESCAPED_OUT_FILE=$(printf '%q' "$OUT_FILE")
ESCAPED_CONTAINER_NAME=$(printf '%q' "$CONTAINER_NAME")
cat > /usr/local/bin/update-geo-no-russia.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail

REPO="ckeiituk/geo-no-russia"
OUT_FILE=$ESCAPED_OUT_FILE
CONTAINER_NAME=$ESCAPED_CONTAINER_NAME
TMP_FILE="\$OUT_FILE.tmp"

BASE_DEPS=(curl jq sha256sum)
for cmd in "\${BASE_DEPS[@]}"; do
  command -v "\$cmd" &>/dev/null || { echo "[!] Missing: \$cmd"; exit 1; }
done

HAS_DOCKER=1
if ! command -v docker &>/dev/null; then
  HAS_DOCKER=0
  echo "[!] docker not found; skipping container reload"
fi

RELEASE_URL=\$(curl -fsSL "https://api.github.com/repos/\$REPO/releases/latest" \\
  | jq -r '.assets[] | select(.name=="geo-no-russia.dat") | .browser_download_url')

if [[ -z "\$RELEASE_URL" ]] || [[ "\$RELEASE_URL" == "null" ]]; then
  echo "[!] Failed to fetch release URL"
  exit 1
fi

curl -fsSL "\$RELEASE_URL" -o "\$TMP_FILE"

OLD_HASH="NONE"
[[ -f "\$OUT_FILE" ]] && OLD_HASH=\$(sha256sum "\$OUT_FILE" | awk '{print \$1}')
NEW_HASH=\$(sha256sum "\$TMP_FILE" | awk '{print \$1}')

if [[ "\$OLD_HASH" == "\$NEW_HASH" ]]; then
  echo "[=] No changes (\$NEW_HASH)"
  rm -f "\$TMP_FILE"
  exit 0
fi
mv -f "\$TMP_FILE" "\$OUT_FILE"
echo "[+] Updated: \$OLD_HASH -> \$NEW_HASH"

if [[ \$HAS_DOCKER -eq 1 ]]; then
  if docker ps --format '{{.Names}}' | grep -Fxq "\$CONTAINER_NAME"; then
    echo "[*] Reloading \$CONTAINER_NAME..."
    docker exec "\$CONTAINER_NAME" kill -HUP 1
    echo "[✓] Reload complete"
  else
    echo "[!] Container \$CONTAINER_NAME not running"
  fi
else
  echo "[*] Skipping container reload (docker not installed)"
fi
EOF

chmod +x /usr/local/bin/update-geo-no-russia.sh
log_success "Скрипт создан: /usr/local/bin/update-geo-no-russia.sh"

# Create systemd service
log_info "Настройка systemd service..."
cat > /etc/systemd/system/geo-update.service <<EOF
[Unit]
Description=Update geo-no-russia database
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-geo-no-russia.sh
StandardOutput=journal
StandardError=journal
EOF

log_success "Service создан: /etc/systemd/system/geo-update.service"

# Create systemd timer
log_info "Настройка systemd timer..."
cat > /etc/systemd/system/geo-update.timer <<EOF
[Unit]
Description=Daily update for geo-no-russia.dat

[Timer]
OnCalendar=*-*-* $UPDATE_TIME:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

log_success "Timer создан: /etc/systemd/system/geo-update.timer"

# Enable and start timer
log_info "Активация таймера..."
systemctl daemon-reload
systemctl enable geo-update.timer
systemctl start geo-update.timer

log_success "Таймер активирован"

# Show status
echo
log_success "Установка завершена!"
echo
echo -e "${BLUE}Следующие команды:${NC}"
echo "  Статус таймера:   systemctl status geo-update.timer"
echo "  Следующий запуск: systemctl list-timers geo-update.timer"
echo "  Ручное обновление: systemctl start geo-update.service"
echo "  Логи:             journalctl -u geo-update.service -n 50"
echo
echo -e "${BLUE}Конфигурация Xray:${NC}"
echo '  {'
echo '    "routing": {'
echo '      "rules": ['
echo '        {'
echo '          "type": "field",'
echo '          "domain": ["ext:geo-no-russia.dat:no-russia"],'
echo '          "outboundTag": "proxy"'
echo '        }'
echo '      ]'
echo '    }'
echo '  }'
echo

# Show next run time
NEXT_RUN=$(systemctl list-timers geo-update.timer --no-pager | grep geo-update.timer | awk '{print $1, $2, $3}')
log_info "Следующее обновление: $NEXT_RUN"
