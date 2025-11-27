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

if [[ $EUID -ne 0 ]]; then
  log_error "Запустите скрипт с sudo"
  exit 1
fi

log_info "Удаление geo-no-russia updater (systemd и скрипты)"

# Try to detect data file path from update script
OUT_FILE_PATH=""
if [[ -f /usr/local/bin/update-geo-no-russia.sh ]]; then
  OUT_FILE_LINE=$(grep -E '^OUT_FILE=' /usr/local/bin/update-geo-no-russia.sh | head -n1 || true)
  if [[ -n "${OUT_FILE_LINE:-}" ]]; then
    OUT_FILE_PATH=${OUT_FILE_LINE#OUT_FILE=}
  fi
fi

log_info "Остановка таймера и сервиса (если запущены)..."
systemctl stop geo-update.timer geo-update.service 2>/dev/null || true

log_info "Отключение таймера..."
systemctl disable geo-update.timer 2>/dev/null || true

log_info "Удаление systemd unit файлов..."
rm -f /etc/systemd/system/geo-update.timer
rm -f /etc/systemd/system/geo-update.service

log_info "Удаление скрипта обновления..."
rm -f /usr/local/bin/update-geo-no-russia.sh

log_info "Перезагрузка конфигурации systemd..."
systemctl daemon-reload

if [[ -n "${OUT_FILE_PATH:-}" && -f "$OUT_FILE_PATH" ]]; then
  echo
  log_info "Обнаружен файл базы: $OUT_FILE_PATH"
  read -p "Удалить файл geo-no-russia.dat? [y/N]: " ANSWER </dev/tty || ANSWER=""
  ANSWER=${ANSWER:-N}
  if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
    rm -f "$OUT_FILE_PATH"
    log_success "Файл удалён: $OUT_FILE_PATH"
  else
    log_warn "Файл базы оставлен: $OUT_FILE_PATH"
  fi
fi

echo
log_success "Удаление завершено."
echo
echo -e "${BLUE}Проверьте состояние (опционально):${NC}"
echo "  systemctl list-timers | grep geo-update || true"
echo "  systemctl status geo-update.service || true"

