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
- Опционально пишет отдельный лог `/var/log/asn-blocker.log` с ротацией через `logrotate`

### Использование

```bash
sudo ./asn-blocker.sh init
sudo ./asn-blocker.sh block AS28753
sudo ./asn-blocker.sh block 28753 210644
sudo ./asn-blocker.sh list
sudo ./asn-blocker.sh status
sudo ./asn-blocker.sh check-ip 46.165.199.9
sudo ./asn-blocker.sh refresh
sudo ./asn-blocker.sh unblock AS28753
```

Скачать и установить как локальную команду `asn-blocker`:

```bash
sudo curl -fsSL https://github.com/npvpn/Marzban-scripts/raw/master/asn-blocker.sh -o /usr/local/bin/asn-blocker && sudo chmod +x /usr/local/bin/asn-blocker
```

После установки можно запускать без `./`:

```bash
sudo asn-blocker init
sudo asn-blocker block AS28753
sudo asn-blocker list
```

Расшифровка команд:

- `sudo ./asn-blocker.sh init` — инициализирует структуру `nftables` (таблица, chain, sets и правила блокировки).
- `sudo ./asn-blocker.sh block AS28753` — блокирует один ASN: получает его префиксы и добавляет их в `nftables`.
- `sudo ./asn-blocker.sh block 28753 210644` — блокирует сразу несколько ASN одной командой.
- `sudo ./asn-blocker.sh list` — показывает, какие ASN уже добавлены в блок-лист.
- `sudo ./asn-blocker.sh status` — выводит общий статус: активные ASN и количество загруженных префиксов.
- `sudo ./asn-blocker.sh check-ip 46.165.199.9` — проверяет, попадает ли конкретный IP в текущие заблокированные ASN-префиксы.
- `sudo ./asn-blocker.sh refresh` — обновляет префиксы для всех ранее добавленных ASN.
- `sudo ./asn-blocker.sh unblock AS28753` — удаляет ASN из блок-листа и убирает его префиксы из `nftables`.

### Логирование и хранение

```bash
sudo ./asn-blocker.sh setup-logging
sudo ./asn-blocker.sh logs 200
```

`setup-logging` создаёт:

- `/etc/rsyslog.d/30-asn-blocker.conf`
- `/etc/logrotate.d/asn-blocker` (ежедневная ротация, 14 файлов, сжатие)
