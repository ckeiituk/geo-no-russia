# geo-no-russia: автоматическая установка и обновление базы

Этот репозиторий содержит скрипт установки, который:
- один раз скачивает актуальный `geo-no-russia.dat`;
- настраивает путь к файлу и (опционально) Docker‑контейнер Xray;
- разворачивает отдельный скрипт автообновления;
- настраивает systemd‑service и таймер для ежедневного обновления.

Файл `geo-no-russia.dat` затем можно использовать в Xray/V2Ray как внешний источник доменов через `ext:geo-no-russia.dat:no-russia`.

---

## Требования

- Linux с systemd (проверено на Debian‑подобных системах).
- Права root (скрипт создаёт файлы в `/usr/local/bin` и `/etc/systemd/system`).
- Установленные пакеты:
  - обязательные: `curl`, `jq`, `sha256sum`, `systemctl`;
  - опциональные:
    - `docker` — для автоматического перезапуска контейнера (через `docker restart`);
    - `strings` — только для отображения количества доменов после загрузки.

Пример установки зависимостей для Debian/Ubuntu:

```bash
sudo apt update
sudo apt install curl jq coreutils systemd
```

Docker и `strings` (pkg `binutils`) ставятся по необходимости отдельно.

---

## Быстрый старт (рекомендуемый способ)

Выполнить установку можно одной командой:

```bash
curl -fsSL https://raw.githubusercontent.com/ckeiituk/geo-no-russia/main/install.sh | sudo bash
```

Во время работы скрипт задаст несколько вопросов:
- путь к файлу `geo-no-russia.dat`  
  по умолчанию: `/opt/remnanode/geo-no-russia.dat`;
- имя Docker‑контейнера Xray  
  по умолчанию: `remnanode`;
- время ежедневного обновления в формате `HH:MM` (24‑часовой формат)  
  по умолчанию: `04:00`.

После подтверждения скрипт:
- скачает последнюю версию `geo-no-russia.dat` из релизов GitHub;
- создаст `/usr/local/bin/update-geo-no-russia.sh`;
- создаст и активирует:
  - `geo-update.service`;
  - `geo-update.timer` с ежедневным запуском в указанное время.

---

## Как это работает

После установки:

- `geo-update.timer` — systemd‑таймер, который раз в сутки запускает `geo-update.service`.
- `geo-update.service` — запускает скрипт `/usr/local/bin/update-geo-no-russia.sh`.
- `update-geo-no-russia.sh`:
  - обращается к GitHub API (`ckeiituk/geo-no-russia`) и находит URL последнего релиза `geo-no-russia.dat`;
  - скачивает файл во временный `*.tmp`;
  - сравнивает SHA‑256 старой и новой версий;
  - только при изменении хэша атомарно заменяет файл.

Поведение после обновления:
- если в системе есть `docker`, установщик по умолчанию настраивает автоперезапуск контейнера через `docker restart <имя-контейнера>` (переменная окружения `GEO_NR_RELOAD_CMD` в `geo-update.service`);
- если `docker` отсутствует — выполняется только обновление файла, без перезапуска. При необходимости перезапуск можно настроить вручную через `GEO_NR_RELOAD_CMD` (см. ниже).

---

## Полезные команды после установки

- Проверить статус таймера:

  ```bash
  systemctl status geo-update.timer
  ```

- Посмотреть запланированное время и историю запусков:

  ```bash
  systemctl list-timers geo-update.timer
  ```

- Запустить обновление вручную:

  ```bash
  sudo systemctl start geo-update.service
  ```

- Посмотреть логи обновлений:

  ```bash
  journalctl -u geo-update.service -n 50
  ```

---

## Автоматический перезапуск RemnaNode/Xray (опционально)

`update-geo-no-russia.sh` поддерживает хук перезапуска через переменную окружения `GEO_NR_RELOAD_CMD`.  
Установщик:
- автоматически добавляет в `geo-update.service` строку `Environment="GEO_NR_RELOAD_CMD=docker restart <имя-контейнера>"`, если найден `docker`;
- ничего не добавляет, если Docker не установлен — в этом случае обновление не трогает ноду.

Вы можете заменить команду перезапуска на свою.

Примеры значений `GEO_NR_RELOAD_CMD`:

- Быстрый перезапуск контейнера:

  ```bash
  GEO_NR_RELOAD_CMD="docker restart remnanode"
  ```

- Перезапуск через `docker compose` в каталоге узла:

  ```bash
  GEO_NR_RELOAD_CMD="cd /opt/remnanode && docker compose restart"
  ```

Чтобы привязать это к systemd‑сервису, можно отредактировать `geo-update.service`:

```ini
[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-geo-no-russia.sh
Environment="GEO_NR_RELOAD_CMD=cd /opt/remnanode && docker compose restart"
StandardOutput=journal
StandardError=journal
```

После изменения не забудьте:

```bash
sudo systemctl daemon-reload
sudo systemctl restart geo-update.timer
```

Если `GEO_NR_RELOAD_CMD` не задана, обновление ограничивается только файлом `geo-no-russia.dat`, нода не перезапускается.

---

## Интеграция с Xray

Предполагается, что `geo-no-russia.dat` доступен на хосте и (при использовании Docker) проброшен внутрь контейнера Xray.  
Базовый пример фрагмента конфигурации Xray:

```jsonc
{
  "routing": {
    "rules": [
      {
        "type": "field",
        "domain": ["ext:geo-no-russia.dat:no-russia"],
        "outboundTag": "proxy"
      }
    ]
  }
}
```

Где:
- `geo-no-russia.dat` — путь к файлу внутри контейнера (обычно монтируется из хоста через `-v /opt/remnanode/geo-no-russia.dat:/etc/xray/geo-no-russia.dat`);
- `no-russia` — имя списка внутри файла.

Настройка `outboundTag` и остальной конфигурации Xray остаётся за вами.

---

## Ручная установка из репозитория

Если вы не хотите запускать скрипт через `curl | bash`, можно:

```bash
git clone https://github.com/ckeiituk/geo-no-russia.git
cd geo-no-russia
sudo ./install.sh
```

Содержимое `install.sh` можно просмотреть и отредактировать перед запуском.

---

## Обновление и повторный запуск мастера установки

При необходимости сменить путь к файлу, имя контейнера или время обновления:

1. Скачайте свежую версию `install.sh` (или обновите репозиторий).
2. Запустите:

   ```bash
   sudo ./install.sh
   ```

3. Введите новые параметры. Скрипт:
   - перезапишет `/usr/local/bin/update-geo-no-russia.sh` с новыми значениями;
   - обновит systemd‑файлы `geo-update.service` и `geo-update.timer`;
   - перезапустит таймер.

---

## Удаление

Чтобы полностью удалить авт обновление (таймер, сервис и скрипт), можно использовать встроенный скрипт:

```bash
curl -fsSL https://raw.githubusercontent.com/ckeiituk/geo-no-russia/main/uninstall.sh | sudo bash
```

Скрипт:
- остановит и отключит `geo-update.timer` / `geo-update.service`;
- удалит `/etc/systemd/system/geo-update.timer` и `/etc/systemd/system/geo-update.service`;
- удалит `/usr/local/bin/update-geo-no-russia.sh`;
- при наличии `geo-no-russia.dat` предложит удалить и его (по умолчанию оставляет).

---

## Безопасность

- Скрипт требует root‑прав и пишет файлы в системные директории — запускайте его только на машинах, где доверяете источнику кода.
- Перед использованием однострочника с `curl | bash` вы можете:
  - клонировать репозиторий;
  - просмотреть и проверить `install.sh`;
  - после этого запускать его локально.

---

## Обратная связь

Если вы нашли ошибку или хотите предложить улучшение:
- создайте issue или pull request в репозитории;
- по возможности приложите лог (`journalctl -u geo-update.service`) и описание окружения (дистрибутив, версия Docker/Xray и т.д.).

Это поможет быстрее воспроизвести и исправить проблему.
