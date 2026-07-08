# Marzban-scripts
Скрипты для Marzban

## Установка Marzban
- **Установить Marzban с SQLite**:

```bash
sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban.sh)" @ install
```

- **Установить Marzban с MySQL**:

  ```bash
  sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban.sh)" @ install --database mysql
  ```

- **Установить Marzban с MariaDB**:

  ```bash
  sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban.sh)" @ install --database mariadb
  ```
  
- **Установить Marzban с MariaDB и dev-веткой**:

  ```bash
  sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban.sh)" @ install --database mariadb --dev
  ```

- **Установить Marzban с MariaDB и конкретной версией**:

  ```bash
  sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban.sh)" @ install --database mariadb --version v0.5.2
  ```

- **Обновить или изменить версию Xray-core**:

  ```bash
  sudo marzban core-update
  ```

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
  --non-interactive
```

Дополнительные флаги: `--database mysql|mariadb`, `--version v0.5.2`, `--dev`, `--uvicorn-port 8001`, `--skip-dns-check`, `--skip-cert`, `--skip-firewall`, `--no-logs`.


## Установка Marzban-node
Установить Marzban-node на сервер:
```bash
sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban-node.sh)" @ install
```
Установить Marzban-node на сервер с кастомным именем:
```bash
sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban-node.sh)" @ install --name marzban-node2
```
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

- **Мигрировать существующую ноду на автообновления через Watchtower**:

  ```bash
  sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban-node.sh)" @ migrate
  ```

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
