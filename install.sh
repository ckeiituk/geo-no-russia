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

if ! command -v strings &>/dev/null; then
  log_warn "strings не найден: количество доменов после загрузки показано не будет"
fi

# Interactive configuration
log_info "Конфигурация установки"
echo

# Сбрасываем возможные значения из окружения
OUT_FILE=""
ALLOW_FILE=""
CONTAINER_NAME=""
UPDATE_TIME=""
CONFIRM=""

if ! read -p "Путь к geo-no-russia.dat [/opt/remnanode/geo-no-russia.dat]: " OUT_FILE </dev/tty; then
  OUT_FILE=""
fi
OUT_FILE=${OUT_FILE:-/opt/remnanode/geo-no-russia.dat}

DEFAULT_ALLOW_FILE="$(dirname "$OUT_FILE")/allow-domains-geosite.dat"
if ! read -p "Путь к allow-domains geosite.dat [${DEFAULT_ALLOW_FILE}]: " ALLOW_FILE </dev/tty; then
  ALLOW_FILE=""
fi
ALLOW_FILE=${ALLOW_FILE:-$DEFAULT_ALLOW_FILE}

if ! read -p "Имя Docker контейнера Xray [remnanode]: " CONTAINER_NAME </dev/tty; then
  CONTAINER_NAME=""
fi
CONTAINER_NAME=${CONTAINER_NAME:-remnanode}

if ! read -p "Время обновления (формат HH:MM) [04:00]: " UPDATE_TIME </dev/tty; then
  UPDATE_TIME=""
fi
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
echo "  Файл geo-no-russia.dat: $OUT_FILE"
echo "  Файл allow-domains geosite.dat: $ALLOW_FILE"
echo "  Контейнер: $CONTAINER_NAME"
echo "  Время обновления: $UPDATE_TIME"
echo

if ! read -p "Продолжить? [Y/n]: " CONFIRM </dev/tty; then
  CONFIRM=""
fi
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

ALLOW_DIR=$(dirname "$ALLOW_FILE")
if [[ ! -d "$ALLOW_DIR" ]]; then
  log_info "Создание директории $ALLOW_DIR"
  mkdir -p "$ALLOW_DIR"
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

log_info "Загрузка allow-domains geosite.dat..."
ALLOW_DOWNLOAD_URL="https://github.com/itdoginfo/allow-domains/releases/latest/download/geosite.dat"
if curl -fsSL "$ALLOW_DOWNLOAD_URL" -o "$ALLOW_FILE"; then
  if command -v strings &>/dev/null; then
    ALLOW_DOMAINS=$(strings "$ALLOW_FILE" | grep -c '^[A-Za-z0-9]' || echo "unknown")
    log_success "Файл загружен ($ALLOW_DOMAINS элементов)"
  else
    log_success "Файл загружен"
  fi
else
  log_error "Не удалось загрузить allow-domains файл"
  exit 1
fi

# Create update script
log_info "Создание скрипта обновления..."
ESCAPED_OUT_FILE=$(printf '%q' "$OUT_FILE")
ESCAPED_ALLOW_FILE=$(printf '%q' "$ALLOW_FILE")
ESCAPED_CONTAINER_NAME=$(printf '%q' "$CONTAINER_NAME")
cat > /usr/local/bin/update-geo-no-russia.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail

REPO="ckeiituk/geo-no-russia"
OUT_FILE=$ESCAPED_OUT_FILE
CONTAINER_NAME=$ESCAPED_CONTAINER_NAME
ALLOW_REPO="itdoginfo/allow-domains"
ALLOW_FILE=$ESCAPED_ALLOW_FILE
MAIN_ASSET_NAME="geo-no-russia.dat"
ALLOW_ASSET_NAME="geosite.dat"
ANY_UPDATED=0

BASE_DEPS=(curl jq sha256sum)
for cmd in "\${BASE_DEPS[@]}"; do
  command -v "\$cmd" &>/dev/null || { echo "[!] Missing: \$cmd"; exit 1; }
done

download_and_update() {
  local repo=\$1
  local asset_name=\$2
  local target_file=\$3
  local label=\$4
  local tmp_file="\${target_file}.tmp"

  local release_url
  release_url=\$(curl -fsSL "https://api.github.com/repos/\${repo}/releases/latest" \\
    | jq -r --arg NAME "\$asset_name" '.assets[] | select(.name==$NAME) | .browser_download_url')

  if [[ -z "\$release_url" || "\$release_url" == "null" ]]; then
    echo "[!] \${label}: failed to fetch release URL"
    return 1
  fi

  curl -fsSL "\$release_url" -o "\$tmp_file"

  local old_hash="NONE"
  [[ -f "\$target_file" ]] && old_hash=\$(sha256sum "\$target_file" | awk '{print \$1}')
  local new_hash=\$(sha256sum "\$tmp_file" | awk '{print \$1}')

  if [[ "\$old_hash" == "\$new_hash" ]]; then
    echo "[=] \${label}: no changes (\$new_hash)"
    rm -f "\$tmp_file"
    return 0
  fi

  mv -f "\$tmp_file" "\$target_file"
  echo "[+] \${label}: updated \$old_hash -> \$new_hash"
  ANY_UPDATED=1
}

download_and_update "\$REPO" "\$MAIN_ASSET_NAME" "\$OUT_FILE" "geo-no-russia" || exit 1
download_and_update "\$ALLOW_REPO" "\$ALLOW_ASSET_NAME" "\$ALLOW_FILE" "allow-domains" || exit 1

RELOAD_CMD="\${GEO_NR_RELOAD_CMD:-}"
if [[ -n "\$RELOAD_CMD" && \$ANY_UPDATED -eq 1 ]]; then
  echo "[*] Running reload command..."
  if bash -lc "\$RELOAD_CMD"; then
    echo "[✓] Reload command succeeded"
  else
    echo "[!] Reload command failed"
  fi
fi
EOF

chmod +x /usr/local/bin/update-geo-no-russia.sh
log_success "Скрипт создан: /usr/local/bin/update-geo-no-russia.sh"

# Create systemd service
log_info "Настройка systemd service..."
RELOAD_ENV_LINE=""
if command -v docker &>/dev/null; then
  RELOAD_ENV_LINE="Environment=\"GEO_NR_RELOAD_CMD=docker restart $CONTAINER_NAME\""
  log_info "Автоперезапуск контейнера: docker restart $CONTAINER_NAME"
else
  log_warn "docker не найден: автоперезапуск контейнера недоступен (можно настроить GEO_NR_RELOAD_CMD вручную в geo-update.service)"
fi
cat > /etc/systemd/system/geo-update.service <<EOF
[Unit]
Description=Update geo-no-russia database
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-geo-no-russia.sh
$RELOAD_ENV_LINE
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
ALLOW_BASENAME=$(basename "$ALLOW_FILE")
echo "  Дополнительный geosite (allow-domains): $ALLOW_FILE"
echo "  Пример правила: \"domain\": [\"ext:${ALLOW_BASENAME}:ANIME\"]"
echo

# Show next run time
NEXT_RUN=$(systemctl list-timers geo-update.timer --no-pager | grep geo-update.timer | awk '{print $1, $2, $3}')
log_info "Следующее обновление: $NEXT_RUN"
