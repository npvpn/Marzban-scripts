# Runbook миграции legacy-бота на платформу

Перенос single-tenant бота (ветка `stable`, legacy PG + legacy Marzban MySQL) в multibot-платформу (`master`: `telegram_bot` + fork `panel`).

Скрипты лежат в `Marzban-scripts/migrate_bot/`. Общая библиотека — `common.sh` (SSH, PG/MySQL-хелперы). **Отдельного «запусти всё одной кнопкой» скрипта нет** — шаги выполняются **по порядку вручную**, с паузами на проверку артефактов и правку `migration.env`.

---

## Два сценария топологии

Выбор сценария — **только через `migration.env`**, новых флагов в скриптах не требуется. Ключевые переменные: `SOURCE_*`, `TARGET_*`, `PANEL_*`.

| | **A. Панель на платформе (internal)** | **B. Панель на отдельном сервере (partner)** |
|---|---|---|
| Где бот после миграции | `TARGET_*` (платформа) | `TARGET_*` (платформа) |
| Где Marzban MySQL после миграции | Тот же хост, что платформа (`PANEL_*` = `TARGET_*`) | Отдельный хост (`PANEL_*` = source/partner) |
| Типичный пример | Старый бот и платформа на одном сервере; fork-панель уже в `nvb_mysql` | MegaSecureBot: бот на `13.140.9.102`, панель на `144.31.19.112` |
| Шаг `08` install-partner | **Пропустить** (fork уже есть) | **Обязателен** (ставим `/opt/marzban`) |
| Шаг `09` MySQL | Дамп legacy → импорт в **platform** MySQL | Дамп legacy → swap → импорт в **partner** MySQL |
| `bots.domain` (target PG) | Пусто или не задавать | Домен partner-панели (для Grafana / API) |
| Grafana Marzban dash | `MYSQL_PASSWORD` из `.env` платформы | `admins.mysql_password` + UFW `3306` с IP платформы |

### Схема A — internal (панель на платформе)

```
[SOURCE legacy]          [TARGET = платформа]
  PG (бот)        ──02──►  PG (multibot)     ← 03 импорт
  MySQL legacy    ──09──►  nvb_mysql (fork)  ← PANEL_* = TARGET_*
  бот останавливается      бот + панель живут здесь
```

### Схема B — partner (панель отдельно)

```
[SOURCE]                    [TARGET = платформа]
  legacy PG        ──02──►     PG multibot
  legacy MySQL     ──09──►     (не используется для Marzban users)
  partner /opt/marzban ◄──08   бот + Grafana
       ▲
       └── PANEL_* указывает сюда; бот ходит в API по bots.domain
```

---

## Быстрые ответы на частые вопросы

### Есть ли скрипт «запустить 00–09 одной командой»?

**Нет.** `common.sh` — это **библиотека**, её подключают остальные скрипты (`source common.sh`). Она не запускает пайплайн.

Шаги **нельзя** свести в один безусловный `for`, потому что:

- между `08` и `09` нужно **обновить `PANEL_*`** в `migration.env`;
- после `02` нужен каталог `./artifacts/<RUN_ID>/pg_export` для `03`–`07` (CSV + `source_env_files.tgz` + `source_files.tgz` с картинками сообщений);
- `09` может упасть наполовине → resume через `RESUME_RUN_ID=...`;
- перед cutover нужна **заморозка** source-бота и ручные smoke-тесты.

Рекомендуемый порядок — таблица ниже (номера файлов ≠ порядок выполнения).

### Достаточно ли поменять env для другого сценария?

**Да.** Дополнительных параметров топологии в коде нет. Меняете:

- `SOURCE_*` / `TARGET_*` — откуда читаем legacy, куда импортируем PG;
- `PANEL_*` — куда смотрят шаги `04`–`07`, `09` (MySQL панели);
- для сценария A: `PANEL_HOST=$TARGET_HOST`, `PANEL_PATH=$TARGET_PATH`, `PANEL_MYSQL_CONTAINER` = контейнер MySQL на платформе;
- для сценария B: после `08` выставить `PANEL_PATH=/opt/marzban`, `PANEL_MYSQL_CONTAINER=marzban-mysql-1` (имя из `docker ps`);
- `TARGET_BOT_DOMAIN` — домен панели (сценарий B) или пусто (сценарий A). Пишется в `bots.domain`, в `bot_settings.subscription_domain` и в панель `sub_subscription_domain` (поля синкаются). `web_url` веб-кабинета **не** заполняется.
- пропуск шагов `08`/`09` — вручную, по таблице сценария.

---

## Подготовка

### 1. Скопировать конфиг

```bash
cd /path/to/Marzban-scripts/migrate_bot
cp migration.env.example migration.env
chmod 600 migration.env
```

Секреты (`TARGET_BOT_API_TOKEN`, пароли Marzban, `PARTNER_MYSQL_PASSWORD`) **не коммитить**. При SSH по паролю на source:

```bash
export MIGRATION_SSH_PASSWORD='...'   # или PANEL_SSH_PASSWORD для partner-хоста
```

### 2. Создать бота в админке платформы (до миграции)

В супер-админке **до** запуска скриптов:

1. **Администраторы** — логин, пароль входа, **MySQL пароль Marzban** (для Grafana при external-панели), скопировать **хэш пароля**.
2. Запомнить `admin_id` для `TARGET_BOT_ADMIN_ID`.
3. После миграции — **Боты** → username, API token, при external-панели — **domain** = домен панели.

### 3. Узнать `TARGET_SERVER_ID`

На **target** PG:

```sql
SELECT id, country_id, ip FROM vpn_servers ORDER BY id;
```

Импорт (`03`) проставит всем подпискам `server_id = TARGET_SERVER_ID`. Значение **должно существовать** в `vpn_servers` на платформе, иначе в боте будет ошибка при «Настроить VPN» (нет флага страны).

### 4. Dry-run (обязательно до cutover)

`01_readonly_audit.sh` **ничего не меняет** на source/target: только SSH, SELECT, чтение `.env`. Старый бот продолжает работать.

```bash
./01_readonly_audit.sh
```

Смотреть `./artifacts/<RUN>/audit/dry_run_summary.json`:

- `"ok": true` — можно идти дальше
- `blockers` — пустые обязательные переменные, конфликты PG, несовместимая MySQL-схема
- `settings_preview/` — что шаг `04` запишет в PG (`subscription_domain`, `marzban_subscription`) и в панель (`sub_subscription_domain`, **без** `web_url`)
- `mysql_schema_diff.json` — какие колонки original Marzban переедут в fork (`dest_only_default` = новые поля вроде `bot_id`)

Пока `ok` не true, шаги `00`/`08`/`09` не запускать.

---

## Справочник переменных `migration.env`

### Обязательные всегда

| Переменная | Описание |
|---|---|
| `SOURCE_HOST`, `SOURCE_USER`, `SOURCE_PATH` | Legacy-хост: PG бота + legacy MySQL/Marzban |
| `TARGET_HOST`, `TARGET_USER`, `TARGET_PATH` | Платформа: PG multibot + рантайм бота |
| `PG_CONTAINER` | Имя PG-контейнера (обычно `pg_nvb`) на source и target |
| `MYSQL_CONTAINER` | Legacy MySQL на **source** (обычно `nvb_mysql`) |
| `SOURCE_BOT_USERNAME` | Username legacy-бота в source PG |
| `TARGET_BOT_USERNAME` | Username бота на платформе |
| `TARGET_BOT_ID` | Числовой `bots.id` на платформе (зарезервировать заранее) |
| `TARGET_SERVER_ID` | `vpn_servers.id` на платформе для подписок |
| `TARGET_BOT_API_TOKEN` | Telegram API token (для `00`) |
| `TARGET_BOT_PUBLIC_NAME` | Отображаемое имя |
| `TARGET_BOT_ADMIN_ID` | `admins.id` партнёра на платформе |
| `ARTIFACT_ROOT` | Каталог артефактов (по умолчанию `./artifacts`) |

### Топология панели (`PANEL_*`)

До шага `08` в сценарии B по умолчанию `PANEL_*` = `SOURCE_*` (legacy). **После `08` обязательно переопределить:**

| Переменная | Сценарий A (internal) | Сценарий B (partner) |
|---|---|---|
| `PANEL_HOST` | `=$TARGET_HOST` | IP/hostname source (где `/opt/marzban`) |
| `PANEL_USER` | `=$TARGET_USER` | `root` на source |
| `PANEL_PATH` | `=$TARGET_PATH` | `/opt/marzban` |
| `PANEL_MYSQL_CONTAINER` | `nvb_mysql` на платформе | `marzban-mysql-1` (из `docker ps`) |
| `PANEL_ENV_FILE` | `$TARGET_PATH/.env` | `/opt/marzban/.env` |
| `PANEL_SSH_PASSWORD` | при необходимости | пароль SSH source, если нет ключа |

### Бот на платформе (дополнительно)

| Переменная | Когда нужна |
|---|---|
| `TARGET_BOT_DOMAIN` | **Сценарий B:** домен partner-панели (`app.example.ru`). Пусто в сценарии A. → `bots.domain`, PG `subscription_domain`, панель `sub_subscription_domain`. |
| `TARGET_MARZBAN_ADMIN_*` | Ручные smoke-проверки API панели |
| `SOURCE_MARZBAN_ADMIN_*` | Доступ к legacy-панели при аудите |

### Шаг `08` — только сценарий B

| Переменная | Описание |
|---|---|
| `PARTNER_PANEL_DOMAIN` | Домен панели (A-запись на source) |
| `PARTNER_CERT_EMAIL` | Email для Let's Encrypt |
| `PARTNER_MYSQL_PASSWORD` | = `MYSQL_PASSWORD` в `.env` partner; = **MySQL пароль Marzban** в админке |
| `PARTNER_ADMIN_USERNAME` | Логин админа панели |
| `PARTNER_ADMIN_PASSWORD_HASH` | Argon2-хэш из админки бота |
| `PARTNER_SUBSCRIPTION_TITLE` | Заголовок подписки в клиентах |
| `PARTNER_SUPPORT_TELEGRAM` | @ поддержки без `t.me/` |
| `PARTNER_BOT_TELEGRAM` | @ бота без `t.me/` |
| `PARTNER_BOT_SERVER_IP` | Публичный IPv4 **платформы** (`TARGET_HOST`); UFW откроет MySQL `3306` только для него |
| `PARTNER_PANEL_UVICORN_PORT` | Порт панели (по умолчанию `8001`) |
| `PARTNER_SKIP_DNS_CHECK` / `SKIP_CERT` / `SKIP_FIREWALL` | Пропуск проверок при повторном прогоне |
| `PARTNER_INSTALL_SCRIPT_LOCAL_PATH` | Локальный путь к `marzban.sh` (по умолчанию `../marzban.sh` от каталога скриптов) |

### Шаг `11` — nginx на source (сценарий B)

| Переменная | Описание |
|---|---|
| `PARTNER_PANEL_DOMAIN` / `TARGET_BOT_DOMAIN` | Основной `server_name` и путь Let's Encrypt. Опционально перекрыть `NGINX_DOMAIN` |
| `NGINX_EXTRA_DOMAINS` | Дополнительные домены через запятую (тот же :443 → панель). Сертификат расширяется `--expand` |
| `SKIP_CERT_EXPAND` | `true`: не трогать Let's Encrypt, только nginx `server_name` |
| `PARTNER_PANEL_UVICORN_PORT` | Куда проксировать (по умолчанию `8001`) |

`11` не гасит leftover `pg_nvb`. Сертификат: `/etc/letsencrypt/live/<основной-домен>/` (SAN после `--expand`). Renew переключается на webroot + hook `docker exec nginx_n_nvb nginx -s reload`. A-запись extra-доменов должна указывать на source.

### Шаг `09`

| Переменная | Описание |
|---|---|
| `MYSQL_SWAP_AT_RESTORE` | `true` (default): остановить legacy MySQL/Marzban на source, поднять partner на `:3306`. `false`: partner/panel MySQL уже запущен |
| `LEGACY_MARZBAN_CONTAINER` | Legacy marzban на source (`nvb_marz`) |
| `RESUME_RUN_ID` | Продолжить импорт из `./artifacts/<RUN_ID>/mysql_restore` без повторного дампа |
| `SKIP_NODE_USAGE_TABLES` | `true`: не импортировать `node_usages` / `node_user_usages` (быстрый cutover, статистика нод в Grafana пустая) |
| `PARTNER_MARZBAN_VERSION` | Тег образа `npvpn/panel` |

### SSH

| Переменная | Описание |
|---|---|
| `SSH_KEY` | Путь к ключу (default `~/.ssh/id_ed25519`) |
| `MIGRATION_SSH_PASSWORD` | Пароль для `SOURCE_*` |
| `PANEL_SSH_PASSWORD` | Пароль для `PANEL_*` (если отличается) |

---

## Порядок выполнения (рекомендуемый)

Номера в имени файла — **не** порядок запуска.

| # | Скрипт | Сценарий A | Сценарий B | Что делает |
|---|---|---|---|---|
| 1 | `01_readonly_audit.sh` | ✅ | ✅ | Dry-run: инвентарь, конфликты, preview настроек, schema-diff MySQL. **Нет записей** |
| 2 | `00_create_target_bot.sh` | ✅ | ✅ | Строка `bots` + пустой `bot_settings` на target (нужен токен) |
| 3 | `08_install_partner_panel_source.sh` | ⏭ пропуск | ✅ | `install-partner` на source (`/opt/marzban`) |
| — | *правка `migration.env`* | `PANEL_*`=target | `PANEL_*`=/opt/marzban | Обязательная пауза |
| 4 | `09_mysql_full_dump_restore_source_partner.sh` | ✅* | ✅ | Дамп legacy MySQL → импорт в fork multibot |
| 5 | `02_pg_export_source.sh` | ✅ | ✅ | CSV + `source_env_files.tgz` + `source_files.tgz` (`src/files`) → `./artifacts/<RUN_ID>/pg_export` |
| 6 | `03_pg_import_target.sh ./artifacts/<RUN>/pg_export` | ✅ | ✅ | Импорт PG на target; `server_id` → `TARGET_SERVER_ID`; картинки → `{TARGET_PATH}/src/files/{TARGET_BOT_ID}__*` |
| 7 | `04_apply_settings_from_source_env.sh ./artifacts/<RUN>/pg_export` | ✅ | ✅ | PG `bot_settings` (в т.ч. `marzban_subscription` + `subscription_domain`), платежи, панель `bot_settings` + `global_settings.panel`, JWT legacy |
| 8 | `05_marzban_merge_target.sh ./artifacts/<RUN>/pg_export` | ✅ | ✅ | `users.bot_id`, device_limit (host_bot_association не трогать) |
| 9 | `06_verify_cutover_checks.sh` | ✅ | ✅ | PG + MySQL verify в артефакты |
| 10 | `07_repair_marzban_user_metadata.sh` | опционально | опционально | `users.created_at` для старых `/sub/` токенов |
| 11 | `11_deploy_source_nginx.sh` | — | опционально | Nginx :443 → partner :8001 (без `:8001` в URL подписки) |

\* **Сценарий A, шаг 09:** `PANEL_HOST`/`PANEL_PATH` = target; если platform MySQL уже работает — `MYSQL_SWAP_AT_RESTORE=false`. Дамп по-прежнему с `SOURCE_*` legacy MySQL.

### Resume после сбоя `09`

```bash
RESUME_RUN_ID=20260710T031719Z ./09_mysql_full_dump_restore_source_partner.sh
# быстрый повтор без статистики нод:
RESUME_RUN_ID=20260710T031719Z MYSQL_SWAP_AT_RESTORE=false SKIP_NODE_USAGE_TABLES=true ./09_mysql_full_dump_restore_source_partner.sh
```

---

## Пошагово: сценарий B (partner, отдельная панель)

Пример: MegaSecureBot — legacy на source, бот на target.

### `01` — аудит

```bash
./01_readonly_audit.sh
```

Проверить `./artifacts/<RUN>/audit/`:

- `dry_run_summary.json` — `"ok": true`
- `source_files_inventory.txt` — список картинок из `src/files` (на платформе станут `{TARGET_BOT_ID}__имя`)
- `target_pg_conflicts.txt` — конфликты `tg_user_id` / `subscriptions.id` должны быть **0**;
- `source_pg_audit.txt` — counts, alembic;
- до `08`: в `target_marzban_collisions.txt` режим **legacy** (нет таблицы `bots` в legacy MySQL) — это норма.
- `settings_preview/panel_bot_settings.json` — `sub_subscription_domain` = `TARGET_BOT_DOMAIN`, поля `web_url` нет.

### `00` — запись бота на target

```bash
# TARGET_BOT_API_TOKEN в migration.env или в shell
./00_create_target_bot.sh
```

### `08` — partner-панель на source

Заполнить все `PARTNER_*`, в т.ч. `PARTNER_BOT_SERVER_IP=$TARGET_HOST`.

```bash
./08_install_partner_panel_source.sh
```

Проверка: `https://<PARTNER_PANEL_DOMAIN>:8001/dashboard/` → HTTP 2xx/3xx.

### Обновить `migration.env` перед `09`

```bash
PANEL_PATH=/opt/marzban
PANEL_MYSQL_CONTAINER=marzban-mysql-1   # точное имя из docker ps
PANEL_ENV_FILE=/opt/marzban/.env
TARGET_BOT_DOMAIN=app.megasecure.ru     # домен панели для bots.domain
```

### `09` — MySQL swap + импорт

Legacy MySQL (`nvb_mysql`) **должен быть запущен** на source в начале.

```bash
./09_mysql_full_dump_restore_source_partner.sh
```

Ожидаемо: дамп (complete-insert) → stop legacy → start partner → rewrite колонок под fork → import → `bots` + `users.bot_id` + `source_bot_id` → `marzban restart`.

### `02` → `06` — PG и нормализация

```bash
./02_pg_export_source.sh
EXPORT=./artifacts/<RUN_ID>/pg_export

./03_pg_import_target.sh "$EXPORT"
./04_apply_settings_from_source_env.sh "$EXPORT"
./05_marzban_merge_target.sh "$EXPORT"
./06_verify_cutover_checks.sh
```

### Пост-миграция (сценарий B)

1. **Подписки `server_id`:** если импорт поставил неверный id — исправить вручную:
   ```sql
   UPDATE subscriptions SET server_id = <правильный vpn_servers.id>
   WHERE bot_id = <TARGET_BOT_ID>;
   ```
2. **Grafana:** `admins.mysql_password` = `MYSQL_PASSWORD` marzban; на source UFW: `3306` только с `TARGET_HOST` (делает `install-partner` через `--bot-server-ip`).
3. **Nginx** (сценарий B): `./11_deploy_source_nginx.sh` — `https://<PARTNER_PANEL_DOMAIN>/sub/...` без `:8001`. Берёт домен из `PARTNER_PANEL_DOMAIN` / `TARGET_BOT_DOMAIN`, сертификат `/etc/letsencrypt/live/<домен>/`. Не делает `docker compose down` старого стека.
4. Админка → **Test Marzban**; smoke `/sub/<token>`; один платёж.
5. Grafana: sync дашборда бота в админке (`admins.mysql_password` = `PARTNER_MYSQL_PASSWORD`).
6. Рестарт процесса бота на платформе — проставит webhook.

---

## Пошагово: сценарий A (internal, панель на платформе)

Когда fork multibot-панель **уже** на том же сервере, что и платформа (`nvb_mysql`, `nvb_marz`).

### `migration.env` (пример)

```bash
SOURCE_HOST=213.165.57.217
SOURCE_PATH=/home/old_bot
TARGET_HOST=213.165.57.217
TARGET_PATH=/home/npvpn_prod

PANEL_HOST=213.165.57.217
PANEL_USER=root
PANEL_PATH=/home/npvpn_prod
PANEL_MYSQL_CONTAINER=nvb_mysql
PANEL_ENV_FILE=/home/npvpn_prod/.env

TARGET_BOT_DOMAIN=          # пусто — internal Grafana
MYSQL_SWAP_AT_RESTORE=false # если platform MySQL уже запущен
```

### Отличия от сценария B

| Шаг | Действие |
|---|---|
| `08` | **Не запускать** |
| `09` | Дамп legacy с `SOURCE_*`, импорт в `PANEL_*` (= platform). При уже работающей панели — `MYSQL_SWAP_AT_RESTORE=false` |
| `04`–`06` | `PANEL_*` указывает на platform MySQL |
| Grafana | `bots.domain` пустой → datasource `nvb_mysql:3306`, пароль из `MYSQL_PASSWORD` платформы |

Остальные шаги `01`, `00`, `02`–`07` — как в сценарии B.

---

## Legacy-панель на source (оригинальный Marzban)

Ожидаемый случай для сценария B: на source стоит **оригинальный** Marzban без multibot (`bots`, `users.bot_id`).

1. `01` — audit в legacy-режиме (нет `bots` в MySQL).
2. `08` — ставит **наш fork** в `/opt/marzban`.
3. `09` — дамп legacy → swap `:3306` → импорт в fork-схему.

Оба MySQL используют порт **3306**, но **не одновременно**.

---

## Проверки после `06`

### `target_pg_verify.txt`

| Метрика | Ожидание |
|---|---|
| `fk_missing_users_*` | 0 |
| `subscription_prices_missing_currency` | 0 |
| `subscription_prices_rub_rows` | > 0 (если тарифы в RUB) |
| `wrong_server_id` | 0 |
| `payments_without_subscription` | 0 или объяснимо |

### `target_marzban_verify.txt`

| Метрика | Ожидание |
|---|---|
| `panel_bot` | 1 строка с `TARGET_BOT_USERNAME` |
| `users_for_bot` | ≈ числу подписок/пользователей |
| `missing_tokens` | 0 |
| `host_associations` | как было до merge; 0 = локация всем ботам |

---

## Cutover checklist

- [ ] Заморозить legacy-бота (webhook off / stop container) на финальный прогон.
- [ ] Дельта при новых данных: повтор `02 → 03 → 04 → 05 → 06`.
- [ ] `TARGET_SERVER_ID` совпадает с реальным `vpn_servers.id` на платформе.
- [ ] **Test Marzban** в админке — OK.
- [ ] «Настроить VPN» в Telegram — без ошибок.
- [ ] `/sub/<legacy_token>` — 200 (при необходимости `07`).
- [ ] Один реальный платёж + recurring smoke.
- [ ] Grafana Marzban dashboard — данные (external: UFW + `mysql_password`).
- [ ] Картинки сообщений на target: `{TARGET_PATH}/src/files/{TARGET_BOT_ID}__*.png` (см. `06` → `target_files_verify.txt`).
- [ ] Не гасить source до зелёных проверок.

---

## Справочник скриптов

| Файл | Назначение |
|---|---|
| `common.sh` | Общие функции (не запускать напрямую) |
| `askpass.sh` | SSH askpass для пароля |
| `00_create_target_bot.sh` | INSERT `bots` на target PG |
| `01_readonly_audit.sh` | Dry-run / read-only preflight |
| `02_pg_export_source.sh` | Экспорт source PG в CSV + картинки `src/files` |
| `03_pg_import_target.sh` | Импорт в target PG + копирование картинок как `{bot_id}__*` |
| `04_apply_settings_from_source_env.sh` | Настройки PG + panel + payments + JWT |
| `05_marzban_merge_target.sh` | Нормализация `users.bot_id` / device_limit / `source_bot_id` |
| `06_verify_cutover_checks.sh` | Verify PG + panel MySQL + список `{bot_id}__*` на target |
| `07_repair_marzban_user_metadata.sh` | Repair `created_at` для legacy sub URLs |
| `08_install_partner_panel_source.sh` | Wrapper `install-partner` (сценарий B) |
| `09_mysql_full_dump_restore_source_partner.sh` | Legacy MySQL → fork panel MySQL (schema-safe) |
| `10_merge_partner_users_into_shared_panel.sh` | Сценарий C: INSERT users в живую общую панель (без `host_bot_association`) |
| `11_deploy_source_nginx.sh` | Nginx :443 → partner :8001 (`PARTNER_PANEL_DOMAIN`) |
| `12_repair_host_bot_association.sh` | Снять ошибочные host↔bot связи перенесённого бота |
| `settings_from_env.py` | Маппинг legacy `.env` → текущие bot_settings / panel settings |
| `copy_bot_files.py` | Переименование `имя.ext` → `{bot_id}__имя.ext` |
| `rewrite_mysqldump.py` | Фильтр дампа MySQL под колонки fork |
| `mysql_schema_diff.py` | Сравнение колонок original vs fork (dry-run) |
| `nginx-partner-source.conf.tmpl` | Шаблон vhost для шага `11` |
| `nginx-megasecure-source.conf` | Старый пример MegaSecure (не используется `11`) |

---

## Типичные проблемы

| Симптом | Причина | Решение |
|---|---|---|
| KeyError `None_ru` в «Настроить VPN» | Неверный `subscriptions.server_id` | `UPDATE subscriptions SET server_id=...` на правильный `vpn_servers.id` |
| Тарифы в USD | Старый баг маппинга валют | `03` мапит по `currencies.code`; проверить RUB в target PG |
| `09` упал после дампа | Partner без таблицы `bots` или старый dump без `source_mysql_columns.json` | `RESUME_RUN_ID=<RUN> ./09_...` после `08`; если нет columns json — переснять дамп |
| Логин панели 500, `Table marzban.admins doesn't exist` | `09` оборвался на `marzban up` (already up) **или** во время `08` панель писала в legacy `nvb_mysql` на `:3306`, partner-том пустой | Дамп уже есть. `RESUME_RUN_ID=<RUN> MYSQL_SWAP_AT_RESTORE=false ./09_...` — скрипт сделает `marzban restart` (Alembic) и импорт |
| Grafana пустая (external) | UFW / нет TCP до MySQL | `ufw allow from TARGET_IP to 3306`; `admins.mysql_password` |
| `/sub/` 405 на HEAD | Норма | Проверять GET, не HEAD |
| Browser 500 на `/sub/` | `sub/limited.html` нет в образе | Mount templates (отдельная задача) |
| Bot domain invalid (web) | BotFather domain ≠ URL веба | `/setdomain` в @BotFather |
| После `03` нет картинок у сообщений | Старый прогон `02`/`03` без `src/files` | Повторно `02` (или сразу `03` — он доберёт архив с source) и `03`. Если PG уже импортирован: `SKIP_PG_IMPORT=1 ./03_pg_import_target.sh "$EXPORT"` |

---

## Пример минимального `migration.env` (сценарий B)

```bash
SOURCE_HOST=144.31.19.112
SOURCE_USER=root
SOURCE_PATH=/home/MegaSecureBot
TARGET_HOST=13.140.9.102
TARGET_USER=root
TARGET_PATH=/home/npvpn_prod

PG_CONTAINER=pg_nvb
MYSQL_CONTAINER=nvb_mysql

PANEL_PATH=/opt/marzban
PANEL_MYSQL_CONTAINER=marzban-mysql-1
PANEL_ENV_FILE=/opt/marzban/.env

SOURCE_BOT_USERNAME=MegaSecureBot
TARGET_BOT_USERNAME=MegaSecureBot
TARGET_BOT_ID=27
TARGET_SERVER_ID=2
TARGET_BOT_DOMAIN=app.megasecure.ru

PARTNER_PANEL_DOMAIN=app.megasecure.ru
PARTNER_BOT_SERVER_IP=13.140.9.102
# ... остальные PARTNER_* и секреты

MYSQL_SWAP_AT_RESTORE=true
LEGACY_MARZBAN_CONTAINER=nvb_marz
ARTIFACT_ROOT=./artifacts
```

Не храните реальные пароли и токены в git. `chmod 600 migration.env`.
