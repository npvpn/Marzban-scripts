# Marzban-scripts
Скрипты для Marzban

## Установка Marzban
- **Установить Marzban с SQLite** (без SSL, порт 8000):

```bash
sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban.sh)" @ install
```

- **Установить Marzban с MySQL** (Let's Encrypt, HTTPS :8001). Интерактивно скрипт спросит домен и email:

  ```bash
  sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban.sh)" @ install --database mysql
  ```

  С параметрами:

  ```bash
  sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban.sh)" @ install --database mysql \
    --domain panel.example.com \
    --cert-email admin@example.com \
    --non-interactive
  ```

- **Установить Marzban с MariaDB**:

  ```bash
  sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban.sh)" @ install --database mariadb \
    --domain panel.example.com \
    --cert-email admin@example.com
  ```
  
- **Установить Marzban с MariaDB и dev-веткой**:

  ```bash
  sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban.sh)" @ install --database mariadb --dev \
    --domain panel.example.com \
    --cert-email admin@example.com
  ```

- **Установить Marzban с MariaDB и конкретной версией**:

  ```bash
  sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban.sh)" @ install --database mariadb --version v0.5.2 \
    --domain panel.example.com \
    --cert-email admin@example.com
  ```

Флаги SSL (только mysql/mariadb): `--domain`, `--cert-email`, `--uvicorn-port 8001`, `--skip-dns-check`, `--skip-cert`, `--non-interactive`, `--no-logs`.  
Нужны A-запись домена на сервер, свободный порт 80, Debian/Ubuntu. Админа после установки: `marzban cli admin create`. Панель: `https://<домен>:8001/dashboard/`.

- **Обновить или изменить версию Xray-core**:

  ```bash
  sudo marzban core-update
  ```

## Миграция legacy-бота на платформу

Скрипты переноса single-tenant бота в multibot-платформу: `migrate_bot/`.

```bash
cd migrate_bot
cp migration.env.example migration.env
chmod 600 migration.env
# далее шаги 00–11 по README.md в этом каталоге
```

Подробный runbook: [migrate_bot/README.md](migrate_bot/README.md).

## Установка партнёрской панели

Автоматическая установка для партнёрского сервера (UFW, certbot, SSL, порт 8001, MySQL, администратор панели).

**Перед запуском:** создайте администратора в админке бота и подготовьте логин, пароль MySQL и хеш пароля.

**Интерактивная установка:**

```bash
sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban.sh)" @ install-partner
```

**Неинтерактивная установка:**

```bash
sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban.sh)" @ install-partner \
  --domain z2vpn.npvpn.net \
  --cert-email admin@example.com \
  --mysql-password 'YOUR_MYSQL_PASSWORD' \
  --admin-username partner_admin \
  --admin-password-hash '$argon2id$...' \
  --subscription-title 'My VPN' \
  --support-telegram support_bot \
  --bot-telegram my_vpn_bot \
  --token 'GITHUB_RUNNER_REGISTRATION_TOKEN' \
  --bot-server-ip 1.1.1.1 \
  --non-interactive
```

`--token` — registration token self-hosted runner (репа `npvpn/telegram_bot`, ~1 час).  
Метка runner = `partner-<bot-telegram>` (например `partner-my_vpn_bot`).  
Опционально: `--project-dir /opt/marzban` (по умолчанию), `--skip-runner`.

Дополнительные флаги панели: `--database mysql|mariadb`, `--version v0.5.2`, `--dev`, `--uvicorn-port 8001`, `--bot-server-ip <IPv4>`, `--skip-dns-check`, `--skip-cert`, `--skip-firewall`, `--no-logs`.

--bot-server-ip` — публичный IP платформы бота. UFW разрешит доступ к MySQL `3306/tcp` только для сервера платформы.

Подробности и установка **только runner** (если панель уже стоит): [Установка панели для партнера.md](./Установка%20панели%20для%20партнера.md).

```bash
sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/install-partner-runner.sh)" @ \
  --token 'GITHUB_RUNNER_REGISTRATION_TOKEN' \
  --label partner-my_vpn_bot
```


## Установка Marzban-node
Установить Marzban-node на сервер:
```bash
sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban-node.sh)" @ install
```
Установить Marzban-node на сервер с кастомным именем:
```bash
sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban-node.sh)" @ install --name marzban-node2
```
Вместе с нодой ставится **node_exporter** (`:9100`, host network) для Prometheus на боте. IP бота можно передать сразу — тогда `:9100` откроется только ему (nftables, без включения UFW):

```bash
sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban-node.sh)" @ install --bot-server-ip 1.2.3.4
```

Без флага скрипт спросит IP интерактивно; пустой ввод — exporter поднимется, порт останется публичным. `--skip-firewall` пропускает ограничение порта.

Или можно установить только сам скрипт (`marzban-node` команда) на сервер:
```bash
sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban-node.sh)" @ install-script
```

Для просмотра всех команд используйте `help`:
```marzban-node help```

- **Обновить или изменить версию Xray-core**:

  ```bash
  sudo marzban-node core-update
  ```

- **Мигрировать существующую ноду** (Watchtower, conntrack, node_exporter):

  ```bash
  sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban-node.sh)" @ migrate --bot-server-ip 1.2.3.4
  ```

  То же на одной уже установленной ноде через CLI:

  ```bash
  sudo marzban-node migrate --bot-server-ip 1.2.3.4
  # или: sudo marzban-node update --bot-server-ip 1.2.3.4
  ```

- **Парк нод** (`migrate_nodes.sh`, SSH как root по ключу, IP в `nodes.txt`):

  ```bash
  ./migrate_nodes.sh nodes.txt 20 1.2.3.4
  ```

  Третий аргумент — публичный IPv4 сервера бота (Prometheus).

## Блокировщик ASN для жалоб по ноде

В репозитории есть вспомогательный скрипт `asn-blocker.sh` для быстрой блокировки префиксов ASN назначения через `nftables`, хранения локального состояния и просмотра срабатываний.

### Что делает скрипт

- Ведёт список заблокированных ASN в `/var/lib/asn-blocker/blocked_asns.txt`
- Получает префиксы ASN из RIPE Stat (с fallback на BGPView)
- Загружает префиксы в `nftables`-сеты (`inet asnblock`)
- Блокирует исходящий трафик на префиксы заблокированных ASN
- Добавляет префикс логов `ASN-BLOCK` для заблокированных пакетов
- Всегда настраивает отдельный лог `/var/log/asn-blocker.log` и ротацию через `logrotate`
- Всегда настраивает автообновление префиксов через cron (`/etc/cron.d/asn-blocker-refresh`)

### Быстрая установка как команды `asn-blocker`

```bash
sudo curl -fsSL https://github.com/npvpn/Marzban-scripts/raw/master/asn-blocker.sh -o /usr/local/bin/asn-blocker && \
sudo chmod +x /usr/local/bin/asn-blocker && \
sudo asn-blocker install
```

Команда `install` автоматически:

- устанавливает зависимости (`nftables`, `curl`, `jq`, `ripgrep`, `python3`, `cron`, `rsyslog`, `logrotate`);
- инициализирует `nftables` таблицу/сеты;
- настраивает логирование блокировок;
- добавляет ежедневный cron refresh.

Расшифровка команд:

- `sudo asn-blocker install` — полный bootstrap (зависимости + init + логи + cron).
- `sudo asn-blocker install-deps` — только установка недостающих зависимостей.
- `sudo asn-blocker block AS28753` — блокирует один ASN: получает его префиксы и добавляет их в `nftables`.
- `sudo asn-blocker block 28753 210644` — блокирует сразу несколько ASN одной командой.
- `sudo asn-blocker list` — показывает, какие ASN уже добавлены в блок-лист.
- `sudo asn-blocker status` — выводит общий статус: активные ASN и количество загруженных префиксов.
- `sudo asn-blocker check-ip 46.165.199.9` — проверяет, попадает ли конкретный IP в текущие заблокированные ASN-префиксы.
- `sudo asn-blocker refresh` — обновляет префиксы для всех ранее добавленных ASN.
- `sudo asn-blocker unblock AS28753` — удаляет ASN из блок-листа и убирает его префиксы из `nftables`.
- `sudo asn-blocker logs 200` — показывает последние логи блокировок из `journald` и `/var/log/asn-blocker.log`.
- `sudo asn-blocker cron-status` — показывает текущую cron-задачу автообновления.

### Логирование и хранение

```bash
sudo asn-blocker logs 200
sudo asn-blocker cron-status
```

По умолчанию создаются:

- `/etc/rsyslog.d/30-asn-blocker.conf`
- `/etc/logrotate.d/asn-blocker` (ежедневная ротация, 14 файлов, сжатие)
- `/etc/cron.d/asn-blocker-refresh` (ежедневный refresh в 04:15)
- `/etc/systemd/journald.conf.d/30-asn-blocker.conf` (`ForwardToSyslog=yes` для стабильной доставки kernel-логов в rsyslog)
