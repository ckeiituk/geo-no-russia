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

run_compose_up_service() {
  local compose_file="$1"
  local service_name="$2"
  local compose_dir
  compose_dir=$(dirname "$compose_file")

  local compose_cmd=(docker compose)
  if ! docker compose version &>/dev/null; then
    if command -v docker-compose &>/dev/null; then
      compose_cmd=(docker-compose)
    else
      return 1
    fi
  fi

  (cd "$compose_dir" && "${compose_cmd[@]}" -f "$compose_file" up -d "$service_name")
}

ensure_compose_volume() {
  local compose_path="$1"
  local service_name="$2"
  local host_path="$3"
  local container_path="$4"
  local label="$5"

  if [[ -z "$compose_path" || -z "$service_name" || -z "$host_path" || -z "$container_path" ]]; then
    return 0
  fi

  if [[ ! -f "$compose_path" ]]; then
    log_warn "docker-compose не найден по пути $compose_path (пропускаю $label)"
    return 0
  fi

  if ! command -v python3 &>/dev/null; then
    log_warn "python3 не найден: пропускаю обновление docker-compose для $label"
    return 0
  fi

  if ! COMPOSE_PATH="$compose_path" \
    SERVICE_NAME="$service_name" \
    HOST_PATH="$host_path" \
    CONTAINER_PATH="$container_path" \
    LABEL="$label" \
    python3 <<'PY'
import os
import sys
from pathlib import Path

compose_path = Path(os.environ["COMPOSE_PATH"]).resolve()
service_name = os.environ["SERVICE_NAME"].strip()
host_path = os.environ["HOST_PATH"].strip()
container_path = os.environ["CONTAINER_PATH"].strip()
label = os.environ["LABEL"].strip()

compose_dir = compose_path.parent.resolve()
compose_dir_str = str(compose_dir)
desired_host_abs = os.path.normpath(os.path.abspath(host_path))
desired_container = os.path.normpath(container_path)

try:
    lines = compose_path.read_text().splitlines()
except FileNotFoundError:
    print(f"[docker-compose] файл не найден: {compose_path}")
    sys.exit(1)

def indent_width(text: str) -> int:
    return len(text) - len(text.lstrip(' '))

service_idx = None
service_indent = 0
for idx, line in enumerate(lines):
    stripped = line.strip()
    if not stripped or stripped.startswith('#'):
        continue
    if stripped == f"{service_name}:":
        service_idx = idx
        service_indent = indent_width(line)
        break

if service_idx is None:
    print(f"[docker-compose] сервис '{service_name}' не найден (пропуск)")
    sys.exit(10)

service_block_end = len(lines)
volumes_start = None
volumes_indent = None
volumes_end = None

def normalize_host(value: str):
    value = value.strip()
    if not value:
        return None
    if value[0] in "'\"" and value[-1] == value[0]:
        value = value[1:-1]
    value = os.path.expanduser(value)
    if os.path.isabs(value):
        return os.path.normpath(value)
    return os.path.normpath(str((compose_dir / value).resolve()))

idx = service_idx + 1
while idx < len(lines):
    line = lines[idx]
    stripped = line.strip()
    indent = indent_width(line)

    if stripped and indent <= service_indent:
        service_block_end = idx
        break

    if not stripped:
        idx += 1
        continue

    if volumes_start is None and stripped == "volumes:" and indent > service_indent:
        volumes_start = idx
        volumes_indent = indent
        idx += 1
        continue

    if volumes_start is not None and idx > volumes_start:
        if indent <= volumes_indent and stripped:
            volumes_end = idx
            break
        if indent > volumes_indent and stripped.startswith('-'):
            entry = stripped[1:].strip()
            if not entry:
                idx += 1
                continue
            if entry[0] in "'\"" and entry[-1] == entry[0]:
                entry = entry[1:-1]
            host_part, sep, rest = entry.partition(':')
            if not sep:
                idx += 1
                continue
            container_part = rest
            if ':' in container_part:
                container_part = container_part.split(':', 1)[0]
            host_abs = normalize_host(host_part)
            container_norm = os.path.normpath(container_part.strip())
            if host_abs == desired_host_abs and container_norm == desired_container:
                print(f"[docker-compose] {label}: volume уже присутствует")
                sys.exit(0)
        idx += 1
        continue

    idx += 1

if volumes_start is None:
    volumes_indent = service_indent + 2
    entry_indent = volumes_indent + 2
    insert_idx = service_block_end
    lines.insert(insert_idx, ' ' * volumes_indent + 'volumes:')
    insert_idx += 1
else:
    if volumes_end is None:
        volumes_end = service_block_end
    entry_indent = volumes_indent + 2
    insert_idx = volumes_end if volumes_end is not None else service_block_end

host_entry_value = desired_host_abs
try:
    rel_candidate = os.path.relpath(desired_host_abs, compose_dir_str)
    if not rel_candidate.startswith('..'):
        if not rel_candidate.startswith('.'):
            rel_candidate = f"./{rel_candidate}"
        host_entry_value = rel_candidate
except ValueError:
    pass

volume_value = f"{host_entry_value}:{container_path}"
entry_line = ' ' * entry_indent + f"- '{volume_value}'"
lines.insert(insert_idx, entry_line)

compose_path.write_text('\n'.join(lines) + '\n')
print(f"[docker-compose] {label}: добавлен volume {volume_value}")
PY
  then
    log_warn "docker-compose: не удалось настроить volume для $label"
  fi
}

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
DOCKER_COMPOSE_PATH=""
DOCKER_COMPOSE_SERVICE=""
GEO_CONTAINER_PATH=""
ALLOW_CONTAINER_PATH=""
RESTART_AFTER_INSTALL="0"
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

RESTART_PROMPT="y/N"
RESTART_DEFAULT="n"
if command -v docker &>/dev/null; then
  RESTART_PROMPT="Y/n"
  RESTART_DEFAULT="Y"
fi

RESTART_ANSWER=""
if ! read -p "Перезапустить контейнер после установки? [$RESTART_PROMPT]: " RESTART_ANSWER </dev/tty; then
  RESTART_ANSWER=""
fi
RESTART_ANSWER=${RESTART_ANSWER:-$RESTART_DEFAULT}
if [[ $RESTART_ANSWER =~ ^[Yy]$ ]]; then
  RESTART_AFTER_INSTALL="1"
else
  RESTART_AFTER_INSTALL="0"
fi

DEFAULT_COMPOSE_PATH="$(dirname "$OUT_FILE")/docker-compose.yml"
DEFAULT_COMPOSE_DECISION="n"
COMPOSE_PROMPT="y/N"
if [[ -f "$DEFAULT_COMPOSE_PATH" ]]; then
  DEFAULT_COMPOSE_DECISION="Y"
  COMPOSE_PROMPT="Y/n"
fi

DOCKER_COMPOSE_DECISION=""
if ! read -p "Добавить volume в docker-compose.yml? [$COMPOSE_PROMPT]: " DOCKER_COMPOSE_DECISION </dev/tty; then
  DOCKER_COMPOSE_DECISION=""
fi
DOCKER_COMPOSE_DECISION=${DOCKER_COMPOSE_DECISION:-$DEFAULT_COMPOSE_DECISION}
if [[ $DOCKER_COMPOSE_DECISION =~ ^[Yy]$ ]]; then
  if ! read -p "Путь к docker-compose.yml [$DEFAULT_COMPOSE_PATH]: " DOCKER_COMPOSE_PATH </dev/tty; then
    DOCKER_COMPOSE_PATH=""
  fi
  DOCKER_COMPOSE_PATH=${DOCKER_COMPOSE_PATH:-$DEFAULT_COMPOSE_PATH}

  if [[ ! -f "$DOCKER_COMPOSE_PATH" ]]; then
    log_warn "docker-compose.yml не найден по пути $DOCKER_COMPOSE_PATH. Этап будет пропущен."
    DOCKER_COMPOSE_PATH=""
  else
    if ! read -p "Имя сервиса в docker-compose [$CONTAINER_NAME]: " DOCKER_COMPOSE_SERVICE </dev/tty; then
      DOCKER_COMPOSE_SERVICE=""
    fi
    DOCKER_COMPOSE_SERVICE=${DOCKER_COMPOSE_SERVICE:-$CONTAINER_NAME}

    GEO_DEFAULT_IN_CONTAINER="/usr/local/share/xray/geo-no-russia.dat"
    if ! read -p "Путь внутри контейнера для geo-no-russia.dat [$GEO_DEFAULT_IN_CONTAINER]: " GEO_CONTAINER_PATH </dev/tty; then
      GEO_CONTAINER_PATH=""
    fi
    GEO_CONTAINER_PATH=${GEO_CONTAINER_PATH:-$GEO_DEFAULT_IN_CONTAINER}

    ALLOW_DEFAULT_IN_CONTAINER="/usr/local/share/xray/allow-domains-geosite.dat"
    if ! read -p "Путь внутри контейнера для allow-domains geosite.dat [$ALLOW_DEFAULT_IN_CONTAINER]: " ALLOW_CONTAINER_PATH </dev/tty; then
      ALLOW_CONTAINER_PATH=""
    fi
    ALLOW_CONTAINER_PATH=${ALLOW_CONTAINER_PATH:-$ALLOW_DEFAULT_IN_CONTAINER}
  fi
fi

echo
log_info "Параметры установки:"
echo "  Файл geo-no-russia.dat: $OUT_FILE"
echo "  Файл allow-domains geosite.dat: $ALLOW_FILE"
echo "  Контейнер: $CONTAINER_NAME"
echo "  Время обновления: $UPDATE_TIME"
if [[ -n "$DOCKER_COMPOSE_PATH" ]]; then
  echo "  docker-compose: $DOCKER_COMPOSE_PATH (service: $DOCKER_COMPOSE_SERVICE)"
fi
if [[ $RESTART_AFTER_INSTALL == "1" ]]; then
  echo "  Перезапуск контейнера после установки: Да"
else
  echo "  Перезапуск контейнера после установки: Нет"
fi
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
    | jq -r --arg NAME "\$asset_name" '.assets[] | select(.name==\$NAME) | .browser_download_url')

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

if [[ -n "$DOCKER_COMPOSE_PATH" ]]; then
  log_info "Проверка docker-compose volumes..."
  ensure_compose_volume "$DOCKER_COMPOSE_PATH" "$DOCKER_COMPOSE_SERVICE" "$OUT_FILE" "$GEO_CONTAINER_PATH" "geo-no-russia"
  ensure_compose_volume "$DOCKER_COMPOSE_PATH" "$DOCKER_COMPOSE_SERVICE" "$ALLOW_FILE" "$ALLOW_CONTAINER_PATH" "allow-domains"
fi

if [[ $RESTART_AFTER_INSTALL == "1" ]]; then
  if [[ -n "$DOCKER_COMPOSE_PATH" ]]; then
    log_info "Пересоздание сервиса $DOCKER_COMPOSE_SERVICE через docker compose..."
    if run_compose_up_service "$DOCKER_COMPOSE_PATH" "$DOCKER_COMPOSE_SERVICE"; then
      log_success "docker compose up -d выполнен"
    else
      log_warn "Не удалось выполнить docker compose up -d, пробую docker restart"
      if command -v docker &>/dev/null; then
        if docker restart "$CONTAINER_NAME"; then
          log_success "Контейнер перезапущен"
        else
          log_warn "Не удалось перезапустить контейнер $CONTAINER_NAME"
        fi
      else
        log_warn "docker не найден, пропускаю перезапуск контейнера"
      fi
    fi
  else
    if command -v docker &>/dev/null; then
      log_info "Перезапуск контейнера $CONTAINER_NAME..."
      if docker restart "$CONTAINER_NAME"; then
        log_success "Контейнер перезапущен"
      else
        log_warn "Не удалось перезапустить контейнер $CONTAINER_NAME"
      fi
    else
      log_warn "docker не найден, пропускаю перезапуск контейнера"
    fi
  fi
else
  if [[ -n "$DOCKER_COMPOSE_PATH" ]]; then
    log_warn "Тома в docker-compose обновлены, запустите 'docker compose up -d $DOCKER_COMPOSE_SERVICE' вручную, если ещё не сделали"
  fi
fi

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
if command -v strings &>/dev/null; then
  echo "  Доступные группы (country_code) в allow-domains (top 40):"
  strings "$ALLOW_FILE" | grep -E '^[A-Z0-9_-]{2,32}$' | sort -u | head -n 40 | sed 's/^/    - /'
else
  echo "  (для вывода списка групп установите пакет binutils: команда strings)"
fi
echo

# Show next run time
NEXT_RUN=$(systemctl list-timers geo-update.timer --no-pager | grep geo-update.timer | awk '{print $1, $2, $3}')
log_info "Следующее обновление: $NEXT_RUN"
