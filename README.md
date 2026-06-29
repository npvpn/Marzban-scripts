# Marzban-scripts
Scripts for Marzban

## Installing Marzban
- **Install Marzban with SQLite**:

```bash
sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban.sh)" @ install
```

- **Install Marzban with MySQL**:

  ```bash
  sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban.sh)" @ install --database mysql
  ```

- **Install Marzban with MariaDB**:

  ```bash
  sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban.sh)" @ install --database mariadb
  ```
  
- **Install Marzban with MariaDB and Dev branch**:

  ```bash
  sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban.sh)" @ install --database mariadb --dev
  ```

- **Install Marzban with MariaDB and Manual version**:

  ```bash
  sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban.sh)" @ install --database mariadb --version v0.5.2
  ```

- **Update or Change Xray-core Version**:

  ```bash
  sudo marzban core-update
  ```

## Installing partner panel

Automated install for a partner server (UFW, certbot, SSL, port 8001, MySQL, panel admin).

**Before running:** create an administrator in the bot admin panel and copy the login, MySQL password, and password hash.

**Interactive install:**

```bash
sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban.sh)" @ install-partner
```

**Non-interactive install:**

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

Optional flags: `--database mysql|mariadb`, `--version v0.5.2`, `--dev`, `--uvicorn-port 8001`, `--skip-dns-check`, `--skip-cert`, `--skip-firewall`, `--no-logs`.


## Installing Marzban-node
Install Marzban-node on your server using this command
```bash
sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban-node.sh)" @ install
```
Install Marzban-node on your server using this command with custom name:
```bash
sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban-node.sh)" @ install --name marzban-node2
```
Or you can only install this script (marzban-node command) on your server by using this command
```bash
sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban-node.sh)" @ install-script
```

Use `help` to view all commands:
```marzban-node help```

- **Update or Change Xray-core Version**:

  ```bash
  sudo marzban-node core-update
  ```

- **Migrate existing node to auto-updates via Watchtower**:

  ```bash
  sudo bash -c "$(curl -sL https://github.com/npvpn/Marzban-scripts/raw/master/marzban-node.sh)" @ migrate
  ```
