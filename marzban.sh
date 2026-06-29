#!/usr/bin/env bash
set -e

INSTALL_DIR="/opt"
if [ -z "$APP_NAME" ]; then
    APP_NAME="marzban"
fi
APP_DIR="$INSTALL_DIR/$APP_NAME"
DATA_DIR="/var/lib/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"
LAST_XRAY_CORES=10

# Partner install context (set by install-partner)
PARTNER_MODE="false"
PARTNER_DOMAIN=""
PARTNER_UVICORN_PORT="8001"
PARTNER_CERT_EMAIL=""
PARTNER_MYSQL_PASSWORD=""
PARTNER_ADMIN_USERNAME=""
PARTNER_ADMIN_PASSWORD_HASH=""
PARTNER_SUBSCRIPTION_TITLE=""
PARTNER_SUPPORT_TELEGRAM=""
PARTNER_BOT_TELEGRAM=""
PARTNER_SKIP_DNS_CHECK="false"
PARTNER_SKIP_CERT="false"
PARTNER_SKIP_FIREWALL="false"
PARTNER_NON_INTERACTIVE="false"
PARTNER_NO_LOGS="false"

colorized_echo() {
    local color=$1
    local text=$2
    
    case $color in
        "red")
        printf "\e[91m${text}\e[0m\n";;
        "green")
        printf "\e[92m${text}\e[0m\n";;
        "yellow")
        printf "\e[93m${text}\e[0m\n";;
        "blue")
        printf "\e[94m${text}\e[0m\n";;
        "magenta")
        printf "\e[95m${text}\e[0m\n";;
        "cyan")
        printf "\e[96m${text}\e[0m\n";;
        *)
            echo "${text}"
        ;;
    esac
}

check_running_as_root() {
    if [ "$(id -u)" != "0" ]; then
        colorized_echo red "This command must be run as root."
        exit 1
    fi
}

detect_os() {
    # Detect the operating system
    if [ -f /etc/lsb-release ]; then
        OS=$(lsb_release -si)
    elif [ -f /etc/os-release ]; then
        OS=$(awk -F= '/^NAME/{print $2}' /etc/os-release | tr -d '"')
    elif [ -f /etc/redhat-release ]; then
        OS=$(cat /etc/redhat-release | awk '{print $1}')
    elif [ -f /etc/arch-release ]; then
        OS="Arch"
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}


detect_and_update_package_manager() {
    colorized_echo blue "Updating package manager"
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        PKG_MANAGER="apt-get"
        $PKG_MANAGER update
    elif [[ "$OS" == "CentOS"* ]] || [[ "$OS" == "AlmaLinux"* ]]; then
        PKG_MANAGER="yum"
        $PKG_MANAGER update -y
        $PKG_MANAGER install -y epel-release
    elif [ "$OS" == "Fedora"* ]; then
        PKG_MANAGER="dnf"
        $PKG_MANAGER update
    elif [ "$OS" == "Arch" ]; then
        PKG_MANAGER="pacman"
        $PKG_MANAGER -Sy
    elif [[ "$OS" == "openSUSE"* ]]; then
        PKG_MANAGER="zypper"
        $PKG_MANAGER refresh
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}

install_package () {
    if [ -z $PKG_MANAGER ]; then
        detect_and_update_package_manager
    fi
    
    PACKAGE=$1
    colorized_echo blue "Installing $PACKAGE"
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        $PKG_MANAGER -y install "$PACKAGE"
    elif [[ "$OS" == "CentOS"* ]] || [[ "$OS" == "AlmaLinux"* ]]; then
        $PKG_MANAGER install -y "$PACKAGE"
    elif [ "$OS" == "Fedora"* ]; then
        $PKG_MANAGER install -y "$PACKAGE"
    elif [ "$OS" == "Arch" ]; then
        $PKG_MANAGER -S --noconfirm "$PACKAGE"
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}

install_docker() {
    # Install Docker and Docker Compose using the official installation script
    colorized_echo blue "Installing Docker"
    curl -fsSL https://get.docker.com | sh
    colorized_echo green "Docker installed successfully"
}

detect_compose() {
    # Check if docker compose command exists
    if docker compose version >/dev/null 2>&1; then
        COMPOSE='docker compose'
    elif docker-compose version >/dev/null 2>&1; then
        COMPOSE='docker-compose'
    else
        colorized_echo red "docker compose not found"
        exit 1
    fi
}

install_marzban_script() {
    FETCH_REPO="npvpn/Marzban-scripts"
    SCRIPT_URL="https://github.com/$FETCH_REPO/raw/master/marzban.sh"
    colorized_echo blue "Installing marzban script"
    curl -sSL $SCRIPT_URL | install -m 755 /dev/stdin /usr/local/bin/marzban
    colorized_echo green "marzban script installed successfully"
}

is_marzban_installed() {
    if [ -d $APP_DIR ]; then
        return 0
    else
        return 1
    fi
}

identify_the_operating_system_and_architecture() {
    if [[ "$(uname)" == 'Linux' ]]; then
        case "$(uname -m)" in
            'i386' | 'i686')
                ARCH='32'
            ;;
            'amd64' | 'x86_64')
                ARCH='64'
            ;;
            'armv5tel')
                ARCH='arm32-v5'
            ;;
            'armv6l')
                ARCH='arm32-v6'
                grep Features /proc/cpuinfo | grep -qw 'vfp' || ARCH='arm32-v5'
            ;;
            'armv7' | 'armv7l')
                ARCH='arm32-v7a'
                grep Features /proc/cpuinfo | grep -qw 'vfp' || ARCH='arm32-v5'
            ;;
            'armv8' | 'aarch64')
                ARCH='arm64-v8a'
            ;;
            'mips')
                ARCH='mips32'
            ;;
            'mipsle')
                ARCH='mips32le'
            ;;
            'mips64')
                ARCH='mips64'
                lscpu | grep -q "Little Endian" && ARCH='mips64le'
            ;;
            'mips64le')
                ARCH='mips64le'
            ;;
            'ppc64')
                ARCH='ppc64'
            ;;
            'ppc64le')
                ARCH='ppc64le'
            ;;
            'riscv64')
                ARCH='riscv64'
            ;;
            's390x')
                ARCH='s390x'
            ;;
            *)
                echo "error: The architecture is not supported."
                exit 1
            ;;
        esac
    else
        echo "error: This operating system is not supported."
        exit 1
    fi
}

send_backup_to_telegram() {
    if [ -f "$ENV_FILE" ]; then
        while IFS='=' read -r key value; do
            if [[ -z "$key" || "$key" =~ ^# ]]; then
                continue
            fi
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            if [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
                export "$key"="$value"
            else
                colorized_echo yellow "Skipping invalid line in .env: $key=$value"
            fi
        done < "$ENV_FILE"
    else
        colorized_echo red "Environment file (.env) not found."
        exit 1
    fi

    if [ "$BACKUP_SERVICE_ENABLED" != "true" ]; then
        colorized_echo yellow "Backup service is not enabled. Skipping Telegram upload."
        return
    fi

    local server_ip=$(curl -s ifconfig.me || echo "Unknown IP")
    local latest_backup=$(ls -t "$APP_DIR/backup" | head -n 1)
    local backup_path="$APP_DIR/backup/$latest_backup"

    if [ ! -f "$backup_path" ]; then
        colorized_echo red "No backups found to send."
        return
    fi

    local backup_size=$(du -m "$backup_path" | cut -f1)
    local split_dir="/tmp/marzban_backup_split"
    local is_single_file=true

    mkdir -p "$split_dir"

    if [ "$backup_size" -gt 49 ]; then
        colorized_echo yellow "Backup is larger than 49MB. Splitting the archive..."
        split -b 49M "$backup_path" "$split_dir/part_"
        is_single_file=false
    else
        cp "$backup_path" "$split_dir/part_aa"
    fi


    local backup_time=$(date "+%Y-%m-%d %H:%M:%S %Z")


    for part in "$split_dir"/*; do
        local part_name=$(basename "$part")
        local custom_filename="backup_${part_name}.tar.gz"
        local caption="📦 *Backup Information*\n🌐 *Server IP*: \`${server_ip}\`\n📁 *Backup File*: \`${custom_filename}\`\n⏰ *Backup Time*: \`${backup_time}\`"
        curl -s -F chat_id="$BACKUP_TELEGRAM_CHAT_ID" \
            -F document=@"$part;filename=$custom_filename" \
            -F caption="$(echo -e "$caption" | sed 's/-/\\-/g;s/\./\\./g;s/_/\\_/g')" \
            -F parse_mode="MarkdownV2" \
            "https://api.telegram.org/bot$BACKUP_TELEGRAM_BOT_KEY/sendDocument" >/dev/null 2>&1 && \
        colorized_echo green "Backup part $custom_filename successfully sent to Telegram." || \
        colorized_echo red "Failed to send backup part $custom_filename to Telegram."
    done

    rm -rf "$split_dir"
}

send_backup_error_to_telegram() {
    local error_messages=$1
    local log_file=$2
    local server_ip=$(curl -s ifconfig.me || echo "Unknown IP")
    local error_time=$(date "+%Y-%m-%d %H:%M:%S %Z")
    local message="⚠️ *Backup Error Notification*\n"
    message+="🌐 *Server IP*: \`${server_ip}\`\n"
    message+="❌ *Errors*:\n\`${error_messages//_/\\_}\`\n"
    message+="⏰ *Time*: \`${error_time}\`"


    message=$(echo -e "$message" | sed 's/-/\\-/g;s/\./\\./g;s/_/\\_/g;s/(/\\(/g;s/)/\\)/g')

    local max_length=1000
    if [ ${#message} -gt $max_length ]; then
        message="${message:0:$((max_length - 50))}...\n\`[Message truncated]\`"
    fi


    curl -s -X POST "https://api.telegram.org/bot$BACKUP_TELEGRAM_BOT_KEY/sendMessage" \
        -d chat_id="$BACKUP_TELEGRAM_CHAT_ID" \
        -d parse_mode="MarkdownV2" \
        -d text="$message" >/dev/null 2>&1 && \
    colorized_echo green "Backup error notification sent to Telegram." || \
    colorized_echo red "Failed to send error notification to Telegram."


    if [ -f "$log_file" ]; then
        response=$(curl -s -w "%{http_code}" -o /tmp/tg_response.json \
            -F chat_id="$BACKUP_TELEGRAM_CHAT_ID" \
            -F document=@"$log_file;filename=backup_error.log" \
            -F caption="📜 *Backup Error Log* - ${error_time}" \
            "https://api.telegram.org/bot$BACKUP_TELEGRAM_BOT_KEY/sendDocument")

        http_code="${response:(-3)}"
        if [ "$http_code" -eq 200 ]; then
            colorized_echo green "Backup error log sent to Telegram."
        else
            colorized_echo red "Failed to send backup error log to Telegram. HTTP code: $http_code"
            cat /tmp/tg_response.json
        fi
    else
        colorized_echo red "Log file not found: $log_file"
    fi
}





backup_service() {
    local telegram_bot_key=""
    local telegram_chat_id=""
    local cron_schedule=""
    local interval_hours=""

    colorized_echo blue "====================================="
    colorized_echo blue "      Welcome to Backup Service      "
    colorized_echo blue "====================================="

    if grep -q "BACKUP_SERVICE_ENABLED=true" "$ENV_FILE"; then
        telegram_bot_key=$(awk -F'=' '/^BACKUP_TELEGRAM_BOT_KEY=/ {print $2}' "$ENV_FILE")
        telegram_chat_id=$(awk -F'=' '/^BACKUP_TELEGRAM_CHAT_ID=/ {print $2}' "$ENV_FILE")
        cron_schedule=$(awk -F'=' '/^BACKUP_CRON_SCHEDULE=/ {print $2}' "$ENV_FILE" | tr -d '"')

        if [[ "$cron_schedule" == "0 0 * * *" ]]; then
            interval_hours=24
        else
            interval_hours=$(echo "$cron_schedule" | grep -oP '(?<=\*/)[0-9]+')
        fi

        colorized_echo green "====================================="
        colorized_echo green "Current Backup Configuration:"
        colorized_echo cyan "Telegram Bot API Key: $telegram_bot_key"
        colorized_echo cyan "Telegram Chat ID: $telegram_chat_id"
        colorized_echo cyan "Backup Interval: Every $interval_hours hour(s)"
        colorized_echo green "====================================="
        echo "Choose an option:"
        echo "1. Reconfigure Backup Service"
        echo "2. Remove Backup Service"
        echo "3. Exit"
        read -p "Enter your choice (1-3): " user_choice

        case $user_choice in
            1)
                colorized_echo yellow "Starting reconfiguration..."
                remove_backup_service
                ;;
            2)
                colorized_echo yellow "Removing Backup Service..."
                remove_backup_service
                return
                ;;
            3)
                colorized_echo yellow "Exiting..."
                return
                ;;
            *)
                colorized_echo red "Invalid choice. Exiting."
                return
                ;;
        esac
    else
        colorized_echo yellow "No backup service is currently configured."
    fi

    while true; do
        printf "Enter your Telegram bot API key: "
        read telegram_bot_key
        if [[ -n "$telegram_bot_key" ]]; then
            break
        else
            colorized_echo red "API key cannot be empty. Please try again."
        fi
    done

    while true; do
        printf "Enter your Telegram chat ID: "
        read telegram_chat_id
        if [[ -n "$telegram_chat_id" ]]; then
            break
        else
            colorized_echo red "Chat ID cannot be empty. Please try again."
        fi
    done

    while true; do
        printf "Set up the backup interval in hours (1-24):\n"
        read interval_hours

        if ! [[ "$interval_hours" =~ ^[0-9]+$ ]]; then
            colorized_echo red "Invalid input. Please enter a valid number."
            continue
        fi

        if [[ "$interval_hours" -eq 24 ]]; then
            cron_schedule="0 0 * * *"
            colorized_echo green "Setting backup to run daily at midnight."
            break
        fi

        if [[ "$interval_hours" -ge 1 && "$interval_hours" -le 23 ]]; then
            cron_schedule="0 */$interval_hours * * *"
            colorized_echo green "Setting backup to run every $interval_hours hour(s)."
            break
        else
            colorized_echo red "Invalid input. Please enter a number between 1-24."
        fi
    done

    sed -i '/^BACKUP_SERVICE_ENABLED/d' "$ENV_FILE"
    sed -i '/^BACKUP_TELEGRAM_BOT_KEY/d' "$ENV_FILE"
    sed -i '/^BACKUP_TELEGRAM_CHAT_ID/d' "$ENV_FILE"
    sed -i '/^BACKUP_CRON_SCHEDULE/d' "$ENV_FILE"

    {
        echo ""
        echo "# Backup service configuration"
        echo "BACKUP_SERVICE_ENABLED=true"
        echo "BACKUP_TELEGRAM_BOT_KEY=$telegram_bot_key"
        echo "BACKUP_TELEGRAM_CHAT_ID=$telegram_chat_id"
        echo "BACKUP_CRON_SCHEDULE=\"$cron_schedule\""
    } >> "$ENV_FILE"

    colorized_echo green "Backup service configuration saved in $ENV_FILE."

    local backup_command="$(which bash) -c '$APP_NAME backup'"
    add_cron_job "$cron_schedule" "$backup_command"

    colorized_echo green "Backup service successfully configured."
    if [[ "$interval_hours" -eq 24 ]]; then
        colorized_echo cyan "Backups will be sent to Telegram daily (every 24 hours at midnight)."
    else
        colorized_echo cyan "Backups will be sent to Telegram every $interval_hours hour(s)."
    fi
    colorized_echo green "====================================="
}


add_cron_job() {
    local schedule="$1"
    local command="$2"
    local temp_cron=$(mktemp)

    crontab -l 2>/dev/null > "$temp_cron" || true
    grep -v "$command" "$temp_cron" > "${temp_cron}.tmp" && mv "${temp_cron}.tmp" "$temp_cron"
    echo "$schedule $command # marzban-backup-service" >> "$temp_cron"
    
    if crontab "$temp_cron"; then
        colorized_echo green "Cron job successfully added."
    else
        colorized_echo red "Failed to add cron job. Please check manually."
    fi
    rm -f "$temp_cron"
}

remove_backup_service() {
    colorized_echo red "in process..."


    sed -i '/^# Backup service configuration/d' "$ENV_FILE"
    sed -i '/BACKUP_SERVICE_ENABLED/d' "$ENV_FILE"
    sed -i '/BACKUP_TELEGRAM_BOT_KEY/d' "$ENV_FILE"
    sed -i '/BACKUP_TELEGRAM_CHAT_ID/d' "$ENV_FILE"
    sed -i '/BACKUP_CRON_SCHEDULE/d' "$ENV_FILE"

    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null > "$temp_cron"

    sed -i '/# marzban-backup-service/d' "$temp_cron"

    if crontab "$temp_cron"; then
        colorized_echo green "Backup service task removed from crontab."
    else
        colorized_echo red "Failed to update crontab. Please check manually."
    fi

    rm -f "$temp_cron"

    colorized_echo green "Backup service has been removed."
}

backup_command() {
    local backup_dir="$APP_DIR/backup"
    local temp_dir="/tmp/marzban_backup"
    local timestamp=$(date +"%Y%m%d%H%M%S")
    local backup_file="$backup_dir/backup_$timestamp.tar.gz"
    local error_messages=()
    local log_file="/var/log/marzban_backup_error.log"
    > "$log_file"
    echo "Backup Log - $(date)" > "$log_file"

    if ! command -v rsync >/dev/null 2>&1; then
        detect_os
        install_package rsync
    fi

    rm -rf "$backup_dir"
    mkdir -p "$backup_dir"
    mkdir -p "$temp_dir"

    if [ -f "$ENV_FILE" ]; then
        while IFS='=' read -r key value; do
            if [[ -z "$key" || "$key" =~ ^# ]]; then
                continue
            fi
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            if [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
                export "$key"="$value"
            else
                echo "Skipping invalid line in .env: $key=$value" >> "$log_file"
            fi
        done < "$ENV_FILE"
    else
        error_messages+=("Environment file (.env) not found.")
        echo "Environment file (.env) not found." >> "$log_file"
        send_backup_error_to_telegram "${error_messages[*]}" "$log_file"
        exit 1
    fi

    local db_type=""
    local sqlite_file=""
    if grep -q "image: mariadb" "$COMPOSE_FILE"; then
        db_type="mariadb"
        container_name=$(docker compose -f "$COMPOSE_FILE" ps -q mariadb || echo "mariadb")

    elif grep -q "image: mysql" "$COMPOSE_FILE"; then
        db_type="mysql"
        container_name=$(docker compose -f "$COMPOSE_FILE" ps -q mysql || echo "mysql")

    elif grep -q "SQLALCHEMY_DATABASE_URL = .*sqlite" "$ENV_FILE"; then
        db_type="sqlite"
        sqlite_file=$(grep -Po '(?<=SQLALCHEMY_DATABASE_URL = "sqlite:////).*"' "$ENV_FILE" | tr -d '"')
        if [[ ! "$sqlite_file" =~ ^/ ]]; then
            sqlite_file="/$sqlite_file"
        fi

    fi

    if [ -n "$db_type" ]; then
        echo "Database detected: $db_type" >> "$log_file"
        case $db_type in
            mariadb)
                if ! docker exec "$container_name" mariadb-dump -u root -p"$MYSQL_ROOT_PASSWORD" --all-databases --ignore-database=mysql --ignore-database=performance_schema --ignore-database=information_schema --ignore-database=sys --events --triggers > "$temp_dir/db_backup.sql" 2>>"$log_file"; then
                    error_messages+=("MariaDB dump failed.")
                fi
                ;;
            mysql)
                if ! docker exec "$container_name" mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" marzban --events --triggers  > "$temp_dir/db_backup.sql" 2>>"$log_file"; then
                    error_messages+=("MySQL dump failed.")
                fi
                ;;
            sqlite)
                if [ -f "$sqlite_file" ]; then
                    if ! cp "$sqlite_file" "$temp_dir/db_backup.sqlite" 2>>"$log_file"; then
                        error_messages+=("Failed to copy SQLite database.")
                    fi
                else
                    error_messages+=("SQLite database file not found at $sqlite_file.")
                fi
                ;;
        esac
    fi

    cp "$APP_DIR/.env" "$temp_dir/" 2>>"$log_file"
    cp "$APP_DIR/docker-compose.yml" "$temp_dir/" 2>>"$log_file"
    rsync -av --exclude 'xray-core' --exclude 'mysql' "$DATA_DIR/" "$temp_dir/marzban_data/" >>"$log_file" 2>&1

    if ! tar -czf "$backup_file" -C "$temp_dir" .; then
        error_messages+=("Failed to create backup archive.")
        echo "Failed to create backup archive." >> "$log_file"
    fi

    rm -rf "$temp_dir"

    if [ ${#error_messages[@]} -gt 0 ]; then
        send_backup_error_to_telegram "${error_messages[*]}" "$log_file"
        return
    fi
    colorized_echo green "Backup created: $backup_file"
    send_backup_to_telegram "$backup_file"
}



get_xray_core() {
    identify_the_operating_system_and_architecture
    clear

    validate_version() {
        local version="$1"
        
        local response=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/tags/$version")
        if echo "$response" | grep -q '"message": "Not Found"'; then
            echo "invalid"
        else
            echo "valid"
        fi
    }

    print_menu() {
        clear
        echo -e "\033[1;32m==============================\033[0m"
        echo -e "\033[1;32m      Xray-core Installer     \033[0m"
        echo -e "\033[1;32m==============================\033[0m"
        echo -e "\033[1;33mAvailable Xray-core versions:\033[0m"
        for ((i=0; i<${#versions[@]}; i++)); do
            echo -e "\033[1;34m$((i + 1)):\033[0m ${versions[i]}"
        done
        echo -e "\033[1;32m==============================\033[0m"
        echo -e "\033[1;35mM:\033[0m Enter a version manually"
        echo -e "\033[1;31mQ:\033[0m Quit"
        echo -e "\033[1;32m==============================\033[0m"
    }

    latest_releases=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=$LAST_XRAY_CORES")

    versions=($(echo "$latest_releases" | grep -oP '"tag_name": "\K(.*?)(?=")'))

    while true; do
        print_menu
        read -p "Choose a version to install (1-${#versions[@]}), or press M to enter manually, Q to quit: " choice
        
        if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -le "${#versions[@]}" ]; then
            choice=$((choice - 1))
            selected_version=${versions[choice]}
            break
        elif [ "$choice" == "M" ] || [ "$choice" == "m" ]; then
            while true; do
                read -p "Enter the version manually (e.g., v1.2.3): " custom_version
                if [ "$(validate_version "$custom_version")" == "valid" ]; then
                    selected_version="$custom_version"
                    break 2
                else
                    echo -e "\033[1;31mInvalid version or version does not exist. Please try again.\033[0m"
                fi
            done
        elif [ "$choice" == "Q" ] || [ "$choice" == "q" ]; then
            echo -e "\033[1;31mExiting.\033[0m"
            exit 0
        else
            echo -e "\033[1;31mInvalid choice. Please try again.\033[0m"
            sleep 2
        fi
    done

    echo -e "\033[1;32mSelected version $selected_version for installation.\033[0m"

    # Check if the required packages are installed
    if ! command -v unzip >/dev/null 2>&1; then
        echo -e "\033[1;33mInstalling required packages...\033[0m"
        detect_os
        install_package unzip
    fi
    if ! command -v wget >/dev/null 2>&1; then
        echo -e "\033[1;33mInstalling required packages...\033[0m"
        detect_os
        install_package wget
    fi

    mkdir -p $DATA_DIR/xray-core
    cd $DATA_DIR/xray-core

    xray_filename="Xray-linux-$ARCH.zip"
    xray_download_url="https://github.com/XTLS/Xray-core/releases/download/${selected_version}/${xray_filename}"

    echo -e "\033[1;33mDownloading Xray-core version ${selected_version}...\033[0m"
    wget -q -O "${xray_filename}" "${xray_download_url}"

    echo -e "\033[1;33mExtracting Xray-core...\033[0m"
    unzip -o "${xray_filename}" >/dev/null 2>&1
    rm "${xray_filename}"
}

# Function to update the Marzban Main core
update_core_command() {
    check_running_as_root
    get_xray_core
    # Change the Marzban core
    xray_executable_path="XRAY_EXECUTABLE_PATH=\"/var/lib/marzban/xray-core/xray\""
    
    echo "Changing the Marzban core..."
    # Check if the XRAY_EXECUTABLE_PATH string already exists in the .env file
    if ! grep -q "^XRAY_EXECUTABLE_PATH=" "$ENV_FILE"; then
        # If the string does not exist, add it
        echo "${xray_executable_path}" >> "$ENV_FILE"
    else
        # Update the existing XRAY_EXECUTABLE_PATH line
        sed -i "s~^XRAY_EXECUTABLE_PATH=.*~${xray_executable_path}~" "$ENV_FILE"
    fi
    
    # Restart Marzban
    colorized_echo red "Restarting Marzban..."
    if restart_command -n >/dev/null 2>&1; then
        colorized_echo green "Marzban successfully restarted!"
    else
        colorized_echo red "Marzban restart failed!"
    fi
    colorized_echo blue "Installation of Xray-core version $selected_version completed."
}

get_mysql_bind_address() {
    if [ "$PARTNER_MODE" = "true" ]; then
        echo "0.0.0.0"
    else
        echo "127.0.0.1"
    fi
}

get_marzban_ssl_volume_lines() {
    if [ "$PARTNER_MODE" = "true" ] && [ -n "$PARTNER_DOMAIN" ]; then
        cat <<EOF
      - /etc/letsencrypt/live/${PARTNER_DOMAIN}/fullchain.pem:/etc/letsencrypt/live/${PARTNER_DOMAIN}/fullchain.pem:ro
      - /etc/letsencrypt/live/${PARTNER_DOMAIN}/privkey.pem:/etc/letsencrypt/live/${PARTNER_DOMAIN}/privkey.pem:ro
EOF
    fi
}

configure_partner_ssl_env() {
    local domain=$1
    local port=$2
    local cert_dir="/etc/letsencrypt/live/${domain}"

    sed -i '/^UVICORN_PORT[[:space:]]*=/d' "$ENV_FILE"
    sed -i '/^UVICORN_SSL_CERTFILE[[:space:]]*=/d' "$ENV_FILE"
    sed -i '/^UVICORN_SSL_KEYFILE[[:space:]]*=/d' "$ENV_FILE"
    sed -i '/^# Partner SSL configuration/d' "$ENV_FILE"

    {
        echo ""
        echo "# Partner SSL configuration"
        echo "UVICORN_PORT = ${port}"
        echo "UVICORN_SSL_CERTFILE = \"${cert_dir}/fullchain.pem\""
        echo "UVICORN_SSL_KEYFILE = \"${cert_dir}/privkey.pem\""
    } >> "$ENV_FILE"

    colorized_echo green "Partner SSL settings saved in $ENV_FILE"
}

install_marzban() {
    local marzban_version=$1
    local database_type=$2
    # Fetch releases
    FILES_URL_PREFIX="https://raw.githubusercontent.com/npvpn/panel/master"
    local mysql_bind_address
    local marzban_ssl_volumes
    mysql_bind_address=$(get_mysql_bind_address)
    marzban_ssl_volumes=$(get_marzban_ssl_volume_lines)
    
    mkdir -p "$DATA_DIR"
    mkdir -p "$APP_DIR"
    
    colorized_echo blue "Setting up docker-compose.yml"
    docker_file_path="$APP_DIR/docker-compose.yml"
    
    if [ "$database_type" == "mariadb" ]; then
        # Generate docker-compose.yml with MariaDB content
        cat > "$docker_file_path" <<EOF
services:
  marzban:
    image: npvpn/panel:${marzban_version}
    restart: always
    env_file: .env
    network_mode: host
    volumes:
      - /var/lib/marzban:/var/lib/marzban
      - /var/lib/marzban/logs:/var/lib/marzban-node
${marzban_ssl_volumes}
    depends_on:
      mariadb:
        condition: service_healthy

  mariadb:
    image: mariadb:lts
    env_file: .env
    network_mode: host
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_ROOT_HOST: '%'
      MYSQL_DATABASE: \${MYSQL_DATABASE}
      MYSQL_USER: \${MYSQL_USER}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
    command:
      - --bind-address=${mysql_bind_address}
      - --character_set_server=utf8mb4            # Sets UTF-8 character set for full Unicode support
      - --collation_server=utf8mb4_unicode_ci     # Defines collation for Unicode
      - --host-cache-size=0                       # Disables host cache to prevent DNS issues
      - --innodb-open-files=1024                  # Sets the limit for InnoDB open files
      - --innodb-buffer-pool-size=256M            # Allocates buffer pool size for InnoDB
      - --binlog_expire_logs_seconds=1209600      # Sets binary log expiration to 14 days (2 weeks)
      - --innodb-log-file-size=64M                # Sets InnoDB log file size to balance log retention and performance
      - --innodb-log-files-in-group=2             # Uses two log files to balance recovery and disk I/O
      - --innodb-doublewrite=0                    # Disables doublewrite buffer (reduces disk I/O; may increase data loss risk)
      - --general_log=0                           # Disables general query log to reduce disk usage
      - --slow_query_log=1                        # Enables slow query log for identifying performance issues
      - --slow_query_log_file=/var/lib/mysql/slow.log # Logs slow queries for troubleshooting
      - --long_query_time=2                       # Defines slow query threshold as 2 seconds
    volumes:
      - /var/lib/marzban/mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      start_interval: 3s
      interval: 10s
      timeout: 5s
      retries: 3
EOF
        echo "----------------------------"
        colorized_echo red "Using MariaDB as database"
        echo "----------------------------"
        colorized_echo green "File generated at $APP_DIR/docker-compose.yml"

        # Modify .env file
        colorized_echo blue "Fetching .env file"
        curl -sL "$FILES_URL_PREFIX/.env.example" -o "$APP_DIR/.env"

        # Comment out the SQLite line
        sed -i 's~^\(SQLALCHEMY_DATABASE_URL = "sqlite:////var/lib/marzban/db.sqlite3"\)~#\1~' "$APP_DIR/.env"


        # Add the MySQL connection string
        #echo -e '\nSQLALCHEMY_DATABASE_URL = "mysql+pymysql://marzban:password@127.0.0.1:3306/marzban"' >> "$APP_DIR/.env"

        sed -i 's/^# \(XRAY_JSON = .*\)$/\1/' "$APP_DIR/.env"
        sed -i 's~\(XRAY_JSON = \).*~\1"/var/lib/marzban/xray_config.json"~' "$APP_DIR/.env"


        prompt_for_marzban_password
        MYSQL_ROOT_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
        
        echo "" >> "$ENV_FILE"
        echo "" >> "$ENV_FILE"
        echo "# Database configuration" >> "$ENV_FILE"
        echo "MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD" >> "$ENV_FILE"
        echo "MYSQL_DATABASE=marzban" >> "$ENV_FILE"
        echo "MYSQL_USER=marzban" >> "$ENV_FILE"
        echo "MYSQL_PASSWORD=$MYSQL_PASSWORD" >> "$ENV_FILE"
        
        SQLALCHEMY_DATABASE_URL="mysql+pymysql://marzban:${MYSQL_PASSWORD}@127.0.0.1:3306/marzban"
        
        echo "" >> "$ENV_FILE"
        echo "# SQLAlchemy Database URL" >> "$ENV_FILE"
        echo "SQLALCHEMY_DATABASE_URL=\"$SQLALCHEMY_DATABASE_URL\"" >> "$ENV_FILE"
        
        colorized_echo green "File saved in $APP_DIR/.env"

        if [ "$PARTNER_MODE" = "true" ]; then
            configure_partner_ssl_env "$PARTNER_DOMAIN" "$PARTNER_UVICORN_PORT"
        fi

    elif [ "$database_type" == "mysql" ]; then
        # Generate docker-compose.yml with MySQL content
        cat > "$docker_file_path" <<EOF
services:
  marzban:
    image: npvpn/panel:${marzban_version}
    restart: always
    env_file: .env
    network_mode: host
    volumes:
      - /var/lib/marzban:/var/lib/marzban
      - /var/lib/marzban/logs:/var/lib/marzban-node
${marzban_ssl_volumes}
    depends_on:
      mysql:
        condition: service_healthy

  mysql:
    image: mysql:9.6.0
    env_file: .env
    network_mode: host
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_ROOT_HOST: '%'
      MYSQL_DATABASE: \${MYSQL_DATABASE}
      MYSQL_USER: \${MYSQL_USER}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
    command:
      - --mysqlx=OFF                             # Disables MySQL X Plugin to save resources if X Protocol isn't used
      - --bind-address=${mysql_bind_address}
      - --character_set_server=utf8mb4            # Sets UTF-8 character set for full Unicode support
      - --collation_server=utf8mb4_unicode_ci     # Defines collation for Unicode
      - --log-bin=mysql-bin                       # Enables binary logging for point-in-time recovery
      - --binlog_expire_logs_seconds=1209600      # Sets binary log expiration to 14 days
      - --host-cache-size=0                       # Disables host cache to prevent DNS issues
      - --innodb-open-files=1024                  # Sets the limit for InnoDB open files
      - --innodb-buffer-pool-size=256M            # Allocates buffer pool size for InnoDB
      - --innodb-redo-log-capacity=128M           # Redo log capacity (replaces innodb_log_file_size + innodb_log_files_in_group since MySQL 8.0.30)
      - --general_log=0                           # Disables general query log for lower disk usage
      - --slow_query_log=1                        # Enables slow query log for performance analysis
      - --slow_query_log_file=/var/lib/mysql/slow.log # Logs slow queries for troubleshooting
      - --long_query_time=2                       # Defines slow query threshold as 2 seconds
    volumes:
      - /var/lib/marzban/mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "127.0.0.1", "-u", "marzban", "--password=\${MYSQL_PASSWORD}"]
      start_period: 5s
      interval: 5s
      timeout: 5s
      retries: 55
      
EOF
        echo "----------------------------"
        colorized_echo red "Using MySQL as database"
        echo "----------------------------"
        colorized_echo green "File generated at $APP_DIR/docker-compose.yml"

        # Modify .env file
        colorized_echo blue "Fetching .env file"
        curl -sL "$FILES_URL_PREFIX/.env.example" -o "$APP_DIR/.env"

        # Comment out the SQLite line
        sed -i 's~^\(SQLALCHEMY_DATABASE_URL = "sqlite:////var/lib/marzban/db.sqlite3"\)~#\1~' "$APP_DIR/.env"


        # Add the MySQL connection string
        #echo -e '\nSQLALCHEMY_DATABASE_URL = "mysql+pymysql://marzban:password@127.0.0.1:3306/marzban"' >> "$APP_DIR/.env"

        sed -i 's/^# \(XRAY_JSON = .*\)$/\1/' "$APP_DIR/.env"
        sed -i 's~\(XRAY_JSON = \).*~\1"/var/lib/marzban/xray_config.json"~' "$APP_DIR/.env"


        prompt_for_marzban_password
        MYSQL_ROOT_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
        
        echo "" >> "$ENV_FILE"
        echo "" >> "$ENV_FILE"
        echo "# Database configuration" >> "$ENV_FILE"
        echo "MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD" >> "$ENV_FILE"
        echo "MYSQL_DATABASE=marzban" >> "$ENV_FILE"
        echo "MYSQL_USER=marzban" >> "$ENV_FILE"
        echo "MYSQL_PASSWORD=$MYSQL_PASSWORD" >> "$ENV_FILE"
        
        SQLALCHEMY_DATABASE_URL="mysql+pymysql://marzban:${MYSQL_PASSWORD}@127.0.0.1:3306/marzban"
        
        echo "" >> "$ENV_FILE"
        echo "# SQLAlchemy Database URL" >> "$ENV_FILE"
        echo "SQLALCHEMY_DATABASE_URL=\"$SQLALCHEMY_DATABASE_URL\"" >> "$ENV_FILE"
        
        colorized_echo green "File saved in $APP_DIR/.env"

        if [ "$PARTNER_MODE" = "true" ]; then
            configure_partner_ssl_env "$PARTNER_DOMAIN" "$PARTNER_UVICORN_PORT"
        fi

    else
        echo "----------------------------"
        colorized_echo red "Using SQLite as database"
        echo "----------------------------"
        colorized_echo blue "Fetching compose file"
        curl -sL "$FILES_URL_PREFIX/docker-compose.yml" -o "$docker_file_path"

        # Install requested version
        if [ "$marzban_version" == "latest" ]; then
            yq -i '.services.marzban.image = "npvpn/panel:latest"' "$docker_file_path"
        else
            yq -i ".services.marzban.image = \"npvpn/panel:${marzban_version}\"" "$docker_file_path"
        fi
        echo "Installing $marzban_version version"
        colorized_echo green "File saved in $APP_DIR/docker-compose.yml"


        colorized_echo blue "Fetching .env file"
        curl -sL "$FILES_URL_PREFIX/.env.example" -o "$APP_DIR/.env"

        sed -i 's/^# \(XRAY_JSON = .*\)$/\1/' "$APP_DIR/.env"
        sed -i 's/^# \(SQLALCHEMY_DATABASE_URL = .*\)$/\1/' "$APP_DIR/.env"
        sed -i 's~\(XRAY_JSON = \).*~\1"/var/lib/marzban/xray_config.json"~' "$APP_DIR/.env"
        sed -i 's~\(SQLALCHEMY_DATABASE_URL = \).*~\1"sqlite:////var/lib/marzban/db.sqlite3"~' "$APP_DIR/.env"





        
        colorized_echo green "File saved in $APP_DIR/.env"
    fi
    
    configure_subscription_settings
    colorized_echo blue "Fetching xray config file"
    curl -sL "$FILES_URL_PREFIX/xray_config.json" -o "$DATA_DIR/xray_config.json"
    colorized_echo green "File saved in $DATA_DIR/xray_config.json"
    
    colorized_echo green "Marzban's files downloaded successfully"
}

up_marzban() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" up -d --remove-orphans
}

follow_marzban_logs() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" logs -f
}

status_command() {
    
    # Check if marzban is installed
    if ! is_marzban_installed; then
        echo -n "Status: "
        colorized_echo red "Not Installed"
        exit 1
    fi
    
    detect_compose
    
    if ! is_marzban_up; then
        echo -n "Status: "
        colorized_echo blue "Down"
        exit 1
    fi
    
    echo -n "Status: "
    colorized_echo green "Up"
    
    json=$($COMPOSE -f $COMPOSE_FILE ps -a --format=json)
    services=$(echo "$json" | jq -r 'if type == "array" then .[] else . end | .Service')
    states=$(echo "$json" | jq -r 'if type == "array" then .[] else . end | .State')
    # Print out the service names and statuses
    for i in $(seq 0 $(expr $(echo $services | wc -w) - 1)); do
        service=$(echo $services | cut -d' ' -f $(expr $i + 1))
        state=$(echo $states | cut -d' ' -f $(expr $i + 1))
        echo -n "- $service: "
        if [ "$state" == "running" ]; then
            colorized_echo green $state
        else
            colorized_echo red $state
        fi
    done
}


prompt_for_marzban_password() {
    if [ -n "$MYSQL_PASSWORD" ]; then
        colorized_echo green "Using provided MySQL password for marzban user."
        return
    fi

    colorized_echo cyan "This password will be used to access the database and should be strong."
    colorized_echo cyan "If you do not enter a custom password, a secure 20-character password will be generated automatically."

    read -p "Enter the password for the marzban user (or press Enter to generate a secure default password): " MYSQL_PASSWORD

    if [ -z "$MYSQL_PASSWORD" ]; then
        MYSQL_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
        colorized_echo green "A secure password has been generated automatically."
    fi
    colorized_echo green "This password will be recorded in the .env file for future use."

    sleep 3
}

normalize_telegram_username() {
    local value="$1"
    value=$(echo "$value" | xargs)
    value="${value#@}"
    value=$(echo "$value" | sed -E 's~^https?://t\.me/~~I')
    echo "$value"
}

normalize_domain() {
    local value="$1"
    value=$(echo "$value" | xargs)
    value=$(echo "$value" | sed -E 's~^https?://~~I')
    value="${value%%/*}"
    value="${value%%:*}"
    echo "$value"
}

configure_subscription_settings() {
    colorized_echo blue "Настройка параметров подписки и бота"

    local support_username=""
    local bot_username=""
    local support_url="https://t.me/"
    local bot_url=""
    local profile_title=""
    local profile_title_escaped

    if [ -n "$PARTNER_SUPPORT_TELEGRAM" ]; then
        support_username=$(normalize_telegram_username "$PARTNER_SUPPORT_TELEGRAM")
    elif [ "$PARTNER_NON_INTERACTIVE" = "true" ]; then
        colorized_echo red "Support telegram username is required in non-interactive mode."
        exit 1
    else
        echo "Подсказка: вводите только username без https://t.me/ (допустимо с @ — уберём)."
        printf "Ссылка поддержки — username без https://t.me/ (можно с @): "
        read support_username
        support_username=$(normalize_telegram_username "$support_username")
    fi

    if [ -n "$PARTNER_SUBSCRIPTION_TITLE" ]; then
        profile_title="$PARTNER_SUBSCRIPTION_TITLE"
    elif [ "$PARTNER_NON_INTERACTIVE" = "true" ]; then
        colorized_echo red "Subscription title is required in non-interactive mode."
        exit 1
    else
        printf "Название подписки в клиенте (по умолчанию: Subscription): "
        read profile_title
        if [ -z "$profile_title" ]; then
            profile_title="Subscription"
        fi
    fi
    profile_title_escaped=$(printf '%s' "$profile_title" | sed 's/\"/\\"/g')

    if [ -n "$PARTNER_BOT_TELEGRAM" ]; then
        bot_username=$(normalize_telegram_username "$PARTNER_BOT_TELEGRAM")
    elif [ "$PARTNER_NON_INTERACTIVE" = "true" ]; then
        colorized_echo red "Bot telegram username is required in non-interactive mode."
        exit 1
    else
        printf "Ссылка на бота — username без https://t.me/ (можно с @): "
        read bot_username
        bot_username=$(normalize_telegram_username "$bot_username")
    fi

    if [ -n "$support_username" ]; then
        support_url="https://t.me/$support_username"
    fi
    if [ -n "$bot_username" ]; then
        bot_url="https://t.me/$bot_username"
    else
        bot_url=""
    fi

    sed -i '/^SUB_SUPPORT_URL[[:space:]]*=/d' "$ENV_FILE"
    sed -i '/^SUB_PROFILE_TITLE[[:space:]]*=/d' "$ENV_FILE"
    sed -i '/^BOT_URL[[:space:]]*=/d' "$ENV_FILE"
    sed -i '/^# Subscription and bot configuration/d' "$ENV_FILE"

    {
        echo ""
        echo "# Subscription and bot configuration"
        echo "SUB_SUPPORT_URL = \"$support_url\""
        echo "SUB_PROFILE_TITLE = \"$profile_title_escaped\""
        echo "BOT_URL = \"$bot_url\""
    } >> "$ENV_FILE"

    colorized_echo green "Параметры подписки и бота сохранены в $ENV_FILE"
}

get_server_public_ip() {
    local ip=""
    ip=$(curl -4 -fsS --max-time 10 ifconfig.me 2>/dev/null || true)
    if [ -z "$ip" ]; then
        ip=$(curl -4 -fsS --max-time 10 api.ipify.org 2>/dev/null || true)
    fi
    if [ -z "$ip" ]; then
        ip=$(curl -4 -fsS --max-time 10 icanhazip.com 2>/dev/null || true)
    fi
    echo "$ip"
}

check_domain_dns() {
    local domain=$1
    local server_ip
    local domain_ips
    local resolved_ip

    if [ "$PARTNER_SKIP_DNS_CHECK" = "true" ]; then
        colorized_echo yellow "Skipping DNS check."
        return 0
    fi

    if ! command -v dig >/dev/null 2>&1; then
        install_package dnsutils
    fi

    server_ip=$(get_server_public_ip)
    if [ -z "$server_ip" ]; then
        colorized_echo yellow "Could not detect server public IP. Skipping DNS verification."
        return 0
    fi

    domain_ips=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9.]+$' || true)
    if [ -z "$domain_ips" ]; then
        domain_ips=$(dig +short AAAA "$domain" 2>/dev/null | grep -E ':' || true)
    fi

    if [ -z "$domain_ips" ]; then
        colorized_echo red "DNS records not found for domain: $domain"
        if [ "$PARTNER_NON_INTERACTIVE" = "true" ]; then
            exit 1
        fi
        read -p "Continue anyway? (y/n) " reply
        if [[ ! $reply =~ ^[Yy]$ ]]; then
            exit 1
        fi
        return 0
    fi

    for resolved_ip in $domain_ips; do
        if [ "$resolved_ip" = "$server_ip" ]; then
            colorized_echo green "DNS check passed: $domain -> $server_ip"
            return 0
        fi
    done

    colorized_echo yellow "DNS mismatch: $domain resolves to [$domain_ips], server IP is $server_ip"
    if [ "$PARTNER_NON_INTERACTIVE" = "true" ]; then
        colorized_echo red "Aborting due to DNS mismatch in non-interactive mode."
        exit 1
    fi
    read -p "Continue anyway? (y/n) " reply
    if [[ ! $reply =~ ^[Yy]$ ]]; then
        exit 1
    fi
}

is_port_free() {
    local port=$1
    if command -v ss >/dev/null 2>&1; then
        ! ss -ltn "( sport = :$port )" 2>/dev/null | grep -q ":$port"
        return $?
    fi
    if command -v netstat >/dev/null 2>&1; then
        ! netstat -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$port$"
        return $?
    fi
    return 0
}

configure_partner_firewall() {
    local panel_port="${PARTNER_UVICORN_PORT:-8001}"

    if [ "$PARTNER_SKIP_FIREWALL" = "true" ]; then
        colorized_echo yellow "Skipping firewall configuration."
        return 0
    fi

    if [[ "$OS" != "Ubuntu"* ]] && [[ "$OS" != "Debian"* ]]; then
        colorized_echo yellow "UFW firewall setup is currently supported only on Debian/Ubuntu."
        return 0
    fi

    if ! command -v ufw >/dev/null 2>&1; then
        install_package ufw
    fi

    colorized_echo blue "Configuring UFW firewall"
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 8443/tcp
    ufw allow "${panel_port}/tcp"

    if ufw status 2>/dev/null | grep -q "Status: active"; then
        colorized_echo green "UFW is already enabled."
    else
        ufw --force enable
        colorized_echo green "UFW enabled."
    fi

    colorized_echo green "Firewall rules applied: 22/tcp, 80/tcp, 443/tcp, 8443/tcp, ${panel_port}/tcp"
}

issue_ssl_certificate() {
    local domain=$1
    local email=$2
    local cert_dir="/etc/letsencrypt/live/${domain}"

    if [ "$PARTNER_SKIP_CERT" = "true" ]; then
        colorized_echo yellow "Skipping certificate issuance."
        if [ ! -f "${cert_dir}/fullchain.pem" ] || [ ! -f "${cert_dir}/privkey.pem" ]; then
            colorized_echo red "Certificate files not found at ${cert_dir}"
            exit 1
        fi
        return 0
    fi

    if [ -f "${cert_dir}/fullchain.pem" ] && [ -f "${cert_dir}/privkey.pem" ]; then
        colorized_echo green "Certificate already exists for ${domain}, skipping issuance."
        return 0
    fi

    if [[ "$OS" != "Ubuntu"* ]] && [[ "$OS" != "Debian"* ]]; then
        colorized_echo red "Partner install certificate issuance is currently supported only on Debian/Ubuntu."
        exit 1
    fi

    if ! command -v certbot >/dev/null 2>&1; then
        install_package certbot
    fi

    if ! is_port_free 80; then
        colorized_echo red "Port 80 is in use. Stop the conflicting service before issuing certificates."
        exit 1
    fi

    colorized_echo blue "Issuing SSL certificate for ${domain}"
    certbot certonly \
        --standalone \
        --email "$email" \
        --agree-tos \
        --non-interactive \
        --preferred-challenges http-01 \
        --cert-name "$domain" \
        -d "$domain"

    if [ ! -f "${cert_dir}/fullchain.pem" ] || [ ! -f "${cert_dir}/privkey.pem" ]; then
        colorized_echo red "Certificate issuance failed for ${domain}"
        exit 1
    fi

    colorized_echo green "Certificate issued successfully:"
    colorized_echo cyan "  ${cert_dir}/fullchain.pem"
    colorized_echo cyan "  ${cert_dir}/privkey.pem"
}

wait_for_marzban_ready() {
    local port=$1
    local attempts=60
    local i=0
    local http_code

    colorized_echo blue "Waiting for Marzban to become ready on port ${port}..."
    while [ $i -lt $attempts ]; do
        if is_marzban_up; then
            http_code=$(curl -k -s -o /dev/null -w "%{http_code}" "https://127.0.0.1:${port}/" 2>/dev/null || echo "000")
            if [[ "$http_code" =~ ^[23] ]]; then
                colorized_echo green "Marzban is ready (HTTP ${http_code})."
                return 0
            fi
        fi
        sleep 3
        i=$((i + 1))
    done

    colorized_echo red "Marzban did not become ready within the expected time."
    exit 1
}

create_panel_admin() {
    local username=$1
    local password_hash=$2
    local output

    colorized_echo blue "Creating panel admin: ${username}"
    # -T: no TTY (avoid hanging on hidden prompts). -e: pass hash into the container
    # (host MARZBAN_ADMIN_PASSWORD is not forwarded by docker compose exec by default).
    output=$($COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" exec -T \
        -e CLI_PROG_NAME="marzban cli" \
        -e "MARZBAN_ADMIN_PASSWORD=${password_hash}" \
        marzban marzban-cli admin create \
        -u "$username" \
        --sudo \
        --telegram-id 0 \
        --discord-webhook "" 2>&1) || {
        if echo "$output" | grep -qi "already exists"; then
            colorized_echo yellow "Admin \"${username}\" already exists, skipping creation."
            return 0
        fi
        colorized_echo red "Failed to create panel admin:"
        echo "$output"
        exit 1
    }

    colorized_echo green "Panel admin \"${username}\" created successfully."
}

verify_partner_install() {
    local domain=$1
    local port=$2
    local http_code
    local dashboard_url="https://${domain}:${port}/dashboard/"

    http_code=$(curl -k -s -o /dev/null -w "%{http_code}" "https://${domain}:${port}/" 2>/dev/null || echo "000")
    if [[ "$http_code" =~ ^[23] ]]; then
        colorized_echo green "Panel is reachable (HTTP ${http_code})."
        colorized_echo cyan "Dashboard URL: ${dashboard_url}"
        return 0
    fi

    colorized_echo yellow "Could not verify panel via HTTPS (HTTP ${http_code}). Check firewall and DNS."
    colorized_echo cyan "Expected dashboard URL: ${dashboard_url}"
}

print_post_install_checklist() {
    local domain=$1
    local port=$2

    colorized_echo blue "====================================="
    colorized_echo blue "      Partner install complete"
    colorized_echo blue "====================================="
    colorized_echo green "Panel URL: https://${domain}:${port}/dashboard/"
    colorized_echo green "Panel admin: ${PARTNER_ADMIN_USERNAME}"
    colorized_echo cyan "MySQL password is stored in ${ENV_FILE}"
    echo
    colorized_echo yellow "Next steps in the bot admin panel:"
    echo "  1. Bots -> add bot (domain = ${domain}, link admin ${PARTNER_ADMIN_USERNAME})"
    echo "  2. Use the Test button to verify Marzban connection"
    echo "  3. Bot settings -> configure required modules"
    echo "  4. Configure per-bot payment providers (e.g. YooKassa)"
    echo "  5. Log out and sign in as the partner admin (plain password, not hash)"
    echo
    colorized_echo cyan "Certificate renewal: certbot renew (systemd timer is usually installed with certbot)"
    colorized_echo blue "====================================="
}

require_partner_params() {
    local missing=()

    [ -z "$PARTNER_DOMAIN" ] && missing+=("--domain")
    [ -z "$PARTNER_CERT_EMAIL" ] && missing+=("--cert-email")
    [ -z "$PARTNER_MYSQL_PASSWORD" ] && missing+=("--mysql-password")
    [ -z "$PARTNER_ADMIN_USERNAME" ] && missing+=("--admin-username")
    [ -z "$PARTNER_ADMIN_PASSWORD_HASH" ] && missing+=("--admin-password-hash")
    [ -z "$PARTNER_SUBSCRIPTION_TITLE" ] && missing+=("--subscription-title")
    [ -z "$PARTNER_SUPPORT_TELEGRAM" ] && missing+=("--support-telegram")
    [ -z "$PARTNER_BOT_TELEGRAM" ] && missing+=("--bot-telegram")

    if [ ${#missing[@]} -gt 0 ]; then
        colorized_echo red "Missing required options for non-interactive install: ${missing[*]}"
        exit 1
    fi
}

prompt_partner_install_params() {
    if [ -z "$PARTNER_DOMAIN" ]; then
        read -p "Domain for the partner panel (e.g. z2vpn.npvpn.net): " PARTNER_DOMAIN
    fi
    PARTNER_DOMAIN=$(normalize_domain "$PARTNER_DOMAIN")
    if [ -z "$PARTNER_DOMAIN" ]; then
        colorized_echo red "Domain cannot be empty."
        exit 1
    fi

    if [ -z "$PARTNER_CERT_EMAIL" ]; then
        read -p "Email for Let's Encrypt certificates: " PARTNER_CERT_EMAIL
    fi
    if [ -z "$PARTNER_CERT_EMAIL" ]; then
        colorized_echo red "Certificate email cannot be empty."
        exit 1
    fi

    if [ -z "$PARTNER_MYSQL_PASSWORD" ]; then
        read -s -p "MySQL password (same as in bot admin): " PARTNER_MYSQL_PASSWORD
        echo
    fi
    if [ -z "$PARTNER_MYSQL_PASSWORD" ]; then
        colorized_echo red "MySQL password cannot be empty."
        exit 1
    fi

    if [ -z "$PARTNER_ADMIN_USERNAME" ]; then
        read -p "Panel admin username (from bot admin): " PARTNER_ADMIN_USERNAME
    fi
    if [ -z "$PARTNER_ADMIN_USERNAME" ]; then
        colorized_echo red "Admin username cannot be empty."
        exit 1
    fi

    if [ -z "$PARTNER_ADMIN_PASSWORD_HASH" ]; then
        read -s -p "Admin password hash (from bot admin view): " PARTNER_ADMIN_PASSWORD_HASH
        echo
    fi
    if [ -z "$PARTNER_ADMIN_PASSWORD_HASH" ]; then
        colorized_echo red "Admin password hash cannot be empty."
        exit 1
    fi

    if [ -z "$PARTNER_SUBSCRIPTION_TITLE" ]; then
        read -p "Subscription title in client apps: " PARTNER_SUBSCRIPTION_TITLE
    fi
    if [ -z "$PARTNER_SUBSCRIPTION_TITLE" ]; then
        colorized_echo red "Subscription title cannot be empty."
        exit 1
    fi

    if [ -z "$PARTNER_SUPPORT_TELEGRAM" ]; then
        read -p "Support Telegram username (without t.me/): " PARTNER_SUPPORT_TELEGRAM
    fi
    if [ -z "$PARTNER_SUPPORT_TELEGRAM" ]; then
        colorized_echo red "Support Telegram username cannot be empty."
        exit 1
    fi

    if [ -z "$PARTNER_BOT_TELEGRAM" ]; then
        read -p "Bot Telegram username (without t.me/): " PARTNER_BOT_TELEGRAM
    fi
    if [ -z "$PARTNER_BOT_TELEGRAM" ]; then
        colorized_echo red "Bot Telegram username cannot be empty."
        exit 1
    fi
}

parse_partner_install_args() {
    PARTNER_DATABASE_TYPE="mysql"
    local marzban_version="latest"
    local marzban_version_set="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)
                PARTNER_DOMAIN=$(normalize_domain "$2")
                shift 2
                ;;
            --cert-email)
                PARTNER_CERT_EMAIL="$2"
                shift 2
                ;;
            --mysql-password)
                PARTNER_MYSQL_PASSWORD="$2"
                shift 2
                ;;
            --admin-username)
                PARTNER_ADMIN_USERNAME="$2"
                shift 2
                ;;
            --admin-password-hash)
                PARTNER_ADMIN_PASSWORD_HASH="$2"
                shift 2
                ;;
            --subscription-title)
                PARTNER_SUBSCRIPTION_TITLE="$2"
                shift 2
                ;;
            --support-telegram)
                PARTNER_SUPPORT_TELEGRAM="$2"
                shift 2
                ;;
            --bot-telegram)
                PARTNER_BOT_TELEGRAM="$2"
                shift 2
                ;;
            --database)
                PARTNER_DATABASE_TYPE="$2"
                shift 2
                ;;
            --uvicorn-port)
                PARTNER_UVICORN_PORT="$2"
                shift 2
                ;;
            --version)
                if [[ "$marzban_version_set" == "true" ]]; then
                    colorized_echo red "Error: Cannot use --dev and --version options simultaneously."
                    exit 1
                fi
                marzban_version="$2"
                marzban_version_set="true"
                shift 2
                ;;
            --dev)
                if [[ "$marzban_version_set" == "true" ]]; then
                    colorized_echo red "Error: Cannot use --dev and --version options simultaneously."
                    exit 1
                fi
                marzban_version="dev"
                marzban_version_set="true"
                shift
                ;;
            --skip-dns-check)
                PARTNER_SKIP_DNS_CHECK="true"
                shift
                ;;
            --skip-cert)
                PARTNER_SKIP_CERT="true"
                shift
                ;;
            --skip-firewall)
                PARTNER_SKIP_FIREWALL="true"
                shift
                ;;
            --non-interactive|-y)
                PARTNER_NON_INTERACTIVE="true"
                shift
                ;;
            --no-logs)
                PARTNER_NO_LOGS="true"
                shift
                ;;
            *)
                colorized_echo red "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    PARTNER_MARZBAN_VERSION="$marzban_version"
}

install_partner_command() {
    parse_partner_install_args "$@"
    check_running_as_root

    if [ "$PARTNER_NON_INTERACTIVE" = "true" ]; then
        require_partner_params
    else
        prompt_partner_install_params
    fi

    PARTNER_DOMAIN=$(normalize_domain "$PARTNER_DOMAIN")
    PARTNER_MODE="true"
    MYSQL_PASSWORD="$PARTNER_MYSQL_PASSWORD"

    if is_marzban_installed; then
        colorized_echo red "Marzban is already installed at $APP_DIR"
        if [ "$PARTNER_NON_INTERACTIVE" = "true" ]; then
            colorized_echo red "Aborting: panel already installed. Remove it first or run without --non-interactive."
            exit 1
        fi
        read -p "Do you want to override the previous installation? (y/n) "
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            colorized_echo red "Aborted installation"
            exit 1
        fi
    fi

    detect_os
    if ! command -v jq >/dev/null 2>&1; then
        install_package jq
    fi
    if ! command -v curl >/dev/null 2>&1; then
        install_package curl
    fi
    if ! command -v docker >/dev/null 2>&1; then
        install_docker
    fi
    if ! command -v yq >/dev/null 2>&1; then
        install_yq
    fi
    detect_compose
    install_marzban_script

    check_version_exists() {
        local version=$1
        local repo_url="https://api.github.com/repos/npvpn/panel/releases"
        if [ "$version" == "latest" ] || [ "$version" == "dev" ]; then
            return 0
        fi
        local response
        response=$(curl -s "$repo_url")
        if echo "$response" | jq -e ".[] | select(.tag_name == \"${version}\")" > /dev/null; then
            return 0
        fi
        return 1
    }

    check_domain_dns "$PARTNER_DOMAIN"
    configure_partner_firewall
    issue_ssl_certificate "$PARTNER_DOMAIN" "$PARTNER_CERT_EMAIL"

    local marzban_version="$PARTNER_MARZBAN_VERSION"
    local database_type="$PARTNER_DATABASE_TYPE"

    if [[ "$database_type" != "mysql" && "$database_type" != "mariadb" ]]; then
        colorized_echo red "Partner install supports only mysql or mariadb database."
        exit 1
    fi

    if [[ "$marzban_version" == "latest" || "$marzban_version" == "dev" || "$marzban_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if check_version_exists "$marzban_version"; then
            install_marzban "$marzban_version" "$database_type"
            colorized_echo green "Installing $marzban_version version"
        else
            colorized_echo red "Version $marzban_version does not exist."
            exit 1
        fi
    else
        colorized_echo red "Invalid version format. Please enter a valid version (e.g. v0.5.2)"
        exit 1
    fi

    up_marzban
    wait_for_marzban_ready "$PARTNER_UVICORN_PORT"
    create_panel_admin "$PARTNER_ADMIN_USERNAME" "$PARTNER_ADMIN_PASSWORD_HASH"
    verify_partner_install "$PARTNER_DOMAIN" "$PARTNER_UVICORN_PORT"
    print_post_install_checklist "$PARTNER_DOMAIN" "$PARTNER_UVICORN_PORT"

    if [ "$PARTNER_NO_LOGS" = "false" ]; then
        colorized_echo yellow "Press Ctrl+C to stop following logs."
        follow_marzban_logs
    fi
}

install_command() {
    check_running_as_root

    # Default values
    database_type="sqlite"
    marzban_version="latest"
    marzban_version_set="false"

    # Parse options
    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
            --database)
                database_type="$2"
                shift 2
            ;;
            --dev)
                if [[ "$marzban_version_set" == "true" ]]; then
                    colorized_echo red "Error: Cannot use --dev and --version options simultaneously."
                    exit 1
                fi
                marzban_version="dev"
                marzban_version_set="true"
                shift
            ;;
            --version)
                if [[ "$marzban_version_set" == "true" ]]; then
                    colorized_echo red "Error: Cannot use --dev and --version options simultaneously."
                    exit 1
                fi
                marzban_version="$2"
                marzban_version_set="true"
                shift 2
            ;;
            *)
                echo "Unknown option: $1"
                exit 1
            ;;
        esac
    done

    # Check if marzban is already installed
    if is_marzban_installed; then
        colorized_echo red "Marzban is already installed at $APP_DIR"
        read -p "Do you want to override the previous installation? (y/n) "
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            colorized_echo red "Aborted installation"
            exit 1
        fi
    fi
    detect_os
    if ! command -v jq >/dev/null 2>&1; then
        install_package jq
    fi
    if ! command -v curl >/dev/null 2>&1; then
        install_package curl
    fi
    if ! command -v docker >/dev/null 2>&1; then
        install_docker
    fi
    if ! command -v yq >/dev/null 2>&1; then
        install_yq
    fi
    detect_compose
    install_marzban_script
    # Function to check if a version exists in the GitHub releases
    check_version_exists() {
        local version=$1
        repo_url="https://api.github.com/repos/npvpn/panel/releases"
        if [ "$version" == "latest" ] || [ "$version" == "dev" ]; then
            return 0
        fi
        
        # Fetch the release data from GitHub API
        response=$(curl -s "$repo_url")
        
        # Check if the response contains the version tag
        if echo "$response" | jq -e ".[] | select(.tag_name == \"${version}\")" > /dev/null; then
            return 0
        else
            return 1
        fi
    }
    # Check if the version is valid and exists
    if [[ "$marzban_version" == "latest" || "$marzban_version" == "dev" || "$marzban_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if check_version_exists "$marzban_version"; then
            install_marzban "$marzban_version" "$database_type"
            echo "Installing $marzban_version version"
        else
            echo "Version $marzban_version does not exist. Please enter a valid version (e.g. v0.5.2)"
            exit 1
        fi
    else
        echo "Invalid version format. Please enter a valid version (e.g. v0.5.2)"
        exit 1
    fi
    up_marzban
    follow_marzban_logs
}

install_yq() {
    if command -v yq &>/dev/null; then
        colorized_echo green "yq is already installed."
        return
    fi

    identify_the_operating_system_and_architecture

    local base_url="https://github.com/mikefarah/yq/releases/latest/download"
    local yq_binary=""

    case "$ARCH" in
        '64' | 'x86_64')
            yq_binary="yq_linux_amd64"
            ;;
        'arm32-v7a' | 'arm32-v6' | 'arm32-v5' | 'armv7l')
            yq_binary="yq_linux_arm"
            ;;
        'arm64-v8a' | 'aarch64')
            yq_binary="yq_linux_arm64"
            ;;
        '32' | 'i386' | 'i686')
            yq_binary="yq_linux_386"
            ;;
        *)
            colorized_echo red "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac

    local yq_url="${base_url}/${yq_binary}"
    colorized_echo blue "Downloading yq from ${yq_url}..."

    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        colorized_echo yellow "Neither curl nor wget is installed. Attempting to install curl."
        install_package curl || {
            colorized_echo red "Failed to install curl. Please install curl or wget manually."
            exit 1
        }
    fi


    if command -v curl &>/dev/null; then
        if curl -L "$yq_url" -o /usr/local/bin/yq; then
            chmod +x /usr/local/bin/yq
            colorized_echo green "yq installed successfully!"
        else
            colorized_echo red "Failed to download yq using curl. Please check your internet connection."
            exit 1
        fi
    elif command -v wget &>/dev/null; then
        if wget -O /usr/local/bin/yq "$yq_url"; then
            chmod +x /usr/local/bin/yq
            colorized_echo green "yq installed successfully!"
        else
            colorized_echo red "Failed to download yq using wget. Please check your internet connection."
            exit 1
        fi
    fi


    if ! echo "$PATH" | grep -q "/usr/local/bin"; then
        export PATH="/usr/local/bin:$PATH"
    fi


    hash -r

    if command -v yq &>/dev/null; then
        colorized_echo green "yq is ready to use."
    elif [ -x "/usr/local/bin/yq" ]; then

        colorized_echo yellow "yq is installed at /usr/local/bin/yq but not found in PATH."
        colorized_echo yellow "You can add /usr/local/bin to your PATH environment variable."
    else
        colorized_echo red "yq installation failed. Please try again or install manually."
        exit 1
    fi
}


down_marzban() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" down
}



show_marzban_logs() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" logs
}

follow_marzban_logs() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" logs -f
}

marzban_cli() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" exec -e CLI_PROG_NAME="marzban cli" marzban marzban-cli "$@"
}


is_marzban_up() {
    if [ -z "$($COMPOSE -f $COMPOSE_FILE ps -q -a)" ]; then
        return 1
    else
        return 0
    fi
}

uninstall_command() {
    check_running_as_root
    # Check if marzban is installed
    if ! is_marzban_installed; then
        colorized_echo red "Marzban's not installed!"
        exit 1
    fi
    
    read -p "Do you really want to uninstall Marzban? (y/n) "
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        colorized_echo red "Aborted"
        exit 1
    fi
    
    detect_compose
    if is_marzban_up; then
        down_marzban
    fi
    uninstall_marzban_script
    uninstall_marzban
    uninstall_marzban_docker_images
    
    read -p "Do you want to remove Marzban's data files too ($DATA_DIR)? (y/n) "
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        colorized_echo green "Marzban uninstalled successfully"
    else
        uninstall_marzban_data_files
        colorized_echo green "Marzban uninstalled successfully"
    fi
}

uninstall_marzban_script() {
    if [ -f "/usr/local/bin/marzban" ]; then
        colorized_echo yellow "Removing marzban script"
        rm "/usr/local/bin/marzban"
    fi
}

uninstall_marzban() {
    if [ -d "$APP_DIR" ]; then
        colorized_echo yellow "Removing directory: $APP_DIR"
        rm -r "$APP_DIR"
    fi
}

uninstall_marzban_docker_images() {
    images=$(docker images | grep marzban | awk '{print $3}')
    
    if [ -n "$images" ]; then
        colorized_echo yellow "Removing Docker images of Marzban"
        for image in $images; do
            if docker rmi "$image" >/dev/null 2>&1; then
                colorized_echo yellow "Image $image removed"
            fi
        done
    fi
}

uninstall_marzban_data_files() {
    if [ -d "$DATA_DIR" ]; then
        colorized_echo yellow "Removing directory: $DATA_DIR"
        rm -r "$DATA_DIR"
    fi
}

restart_command() {
    help() {
        colorized_echo red "Usage: marzban restart [options]"
        echo
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-logs     do not follow logs after starting"
    }
    
    local no_logs=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -n|--no-logs)
                no_logs=true
            ;;
            -h|--help)
                help
                exit 0
            ;;
            *)
                echo "Error: Invalid option: $1" >&2
                help
                exit 0
            ;;
        esac
        shift
    done
    
    # Check if marzban is installed
    if ! is_marzban_installed; then
        colorized_echo red "Marzban's not installed!"
        exit 1
    fi
    
    detect_compose
    
    down_marzban
    up_marzban
    if [ "$no_logs" = false ]; then
        follow_marzban_logs
    fi
    colorized_echo green "Marzban successfully restarted!"
}
logs_command() {
    help() {
        colorized_echo red "Usage: marzban logs [options]"
        echo ""
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-follow   do not show follow logs"
    }
    
    local no_follow=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -n|--no-follow)
                no_follow=true
            ;;
            -h|--help)
                help
                exit 0
            ;;
            *)
                echo "Error: Invalid option: $1" >&2
                help
                exit 0
            ;;
        esac
        shift
    done
    
    # Check if marzban is installed
    if ! is_marzban_installed; then
        colorized_echo red "Marzban's not installed!"
        exit 1
    fi
    
    detect_compose
    
    if ! is_marzban_up; then
        colorized_echo red "Marzban is not up."
        exit 1
    fi
    
    if [ "$no_follow" = true ]; then
        show_marzban_logs
    else
        follow_marzban_logs
    fi
}

down_command() {
    
    # Check if marzban is installed
    if ! is_marzban_installed; then
        colorized_echo red "Marzban's not installed!"
        exit 1
    fi
    
    detect_compose
    
    if ! is_marzban_up; then
        colorized_echo red "Marzban's already down"
        exit 1
    fi
    
    down_marzban
}

cli_command() {
    # Check if marzban is installed
    if ! is_marzban_installed; then
        colorized_echo red "Marzban's not installed!"
        exit 1
    fi
    
    detect_compose
    
    if ! is_marzban_up; then
        colorized_echo red "Marzban is not up."
        exit 1
    fi
    
    marzban_cli "$@"
}

up_command() {
    help() {
        colorized_echo red "Usage: marzban up [options]"
        echo ""
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-logs     do not follow logs after starting"
    }
    
    local no_logs=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -n|--no-logs)
                no_logs=true
            ;;
            -h|--help)
                help
                exit 0
            ;;
            *)
                echo "Error: Invalid option: $1" >&2
                help
                exit 0
            ;;
        esac
        shift
    done
    
    # Check if marzban is installed
    if ! is_marzban_installed; then
        colorized_echo red "Marzban's not installed!"
        exit 1
    fi
    
    detect_compose
    
    if is_marzban_up; then
        colorized_echo red "Marzban's already up"
        exit 1
    fi
    
    up_marzban
    if [ "$no_logs" = false ]; then
        follow_marzban_logs
    fi
}

update_command() {
    check_running_as_root
    # Check if marzban is installed
    if ! is_marzban_installed; then
        colorized_echo red "Marzban's not installed!"
        exit 1
    fi
    
    detect_compose
    
    update_marzban_script
    colorized_echo blue "Pulling latest version"
    update_marzban
    
    colorized_echo blue "Restarting Marzban's services"
    down_marzban
    up_marzban
    
    colorized_echo blue "Marzban updated successfully"
}

update_marzban_script() {
    FETCH_REPO="npvpn/Marzban-scripts"
    SCRIPT_URL="https://github.com/$FETCH_REPO/raw/master/marzban.sh"
    colorized_echo blue "Updating marzban script"
    curl -sSL $SCRIPT_URL | install -m 755 /dev/stdin /usr/local/bin/marzban
    colorized_echo green "marzban script updated successfully"
}

update_marzban() {
    $COMPOSE -f $COMPOSE_FILE -p "$APP_NAME" pull
}

check_editor() {
    if [ -z "$EDITOR" ]; then
        if command -v nano >/dev/null 2>&1; then
            EDITOR="nano"
            elif command -v vi >/dev/null 2>&1; then
            EDITOR="vi"
        else
            detect_os
            install_package nano
            EDITOR="nano"
        fi
    fi
}


edit_command() {
    detect_os
    check_editor
    if [ -f "$COMPOSE_FILE" ]; then
        $EDITOR "$COMPOSE_FILE"
    else
        colorized_echo red "Compose file not found at $COMPOSE_FILE"
        exit 1
    fi
}

edit_env_command() {
    detect_os
    check_editor
    if [ -f "$ENV_FILE" ]; then
        $EDITOR "$ENV_FILE"
    else
        colorized_echo red "Environment file not found at $ENV_FILE"
        exit 1
    fi
}

usage() {
    local script_name="${0##*/}"
    colorized_echo blue "=============================="
    colorized_echo magenta "           Marzban Help"
    colorized_echo blue "=============================="
    colorized_echo cyan "Usage:"
    echo "  ${script_name} [command]"
    echo

    colorized_echo cyan "Commands:"
    colorized_echo yellow "  up              $(tput sgr0)– Start services"
    colorized_echo yellow "  down            $(tput sgr0)– Stop services"
    colorized_echo yellow "  restart         $(tput sgr0)– Restart services"
    colorized_echo yellow "  status          $(tput sgr0)– Show status"
    colorized_echo yellow "  logs            $(tput sgr0)– Show logs"
    colorized_echo yellow "  cli             $(tput sgr0)– Marzban CLI"
    colorized_echo yellow "  install         $(tput sgr0)– Install Marzban"
    colorized_echo yellow "  install-partner $(tput sgr0)– Install partner panel (SSL, certbot, admin)"
    colorized_echo yellow "  update          $(tput sgr0)– Update to latest version"
    colorized_echo yellow "  uninstall       $(tput sgr0)– Uninstall Marzban"
    colorized_echo yellow "  install-script  $(tput sgr0)– Install Marzban script"
    colorized_echo yellow "  backup          $(tput sgr0)– Manual backup launch"
    colorized_echo yellow "  backup-service  $(tput sgr0)– Marzban Backupservice to backup to TG, and a new job in crontab"
    colorized_echo yellow "  core-update     $(tput sgr0)– Update/Change Xray core"
    colorized_echo yellow "  edit            $(tput sgr0)– Edit docker-compose.yml (via nano or vi editor)"
    colorized_echo yellow "  edit-env        $(tput sgr0)– Edit environment file (via nano or vi editor)"
    colorized_echo yellow "  help            $(tput sgr0)– Show this help message"
    
    
    echo
    colorized_echo cyan "Directories:"
    colorized_echo magenta "  App directory: $APP_DIR"
    colorized_echo magenta "  Data directory: $DATA_DIR"
    colorized_echo blue "================================"
    echo
}

case "$1" in
    up)
        shift; up_command "$@";;
    down)
        shift; down_command "$@";;
    restart)
        shift; restart_command "$@";;
    status)
        shift; status_command "$@";;
    logs)
        shift; logs_command "$@";;
    cli)
        shift; cli_command "$@";;
    backup)
        shift; backup_command "$@";;
    backup-service)
        shift; backup_service "$@";;
    install)
        shift; install_command "$@";;
    install-partner)
        shift; install_partner_command "$@";;
    update)
        shift; update_command "$@";;
    uninstall)
        shift; uninstall_command "$@";;
    install-script)
        shift; install_marzban_script "$@";;
    core-update)
        shift; update_core_command "$@";;
    edit)
        shift; edit_command "$@";;
    edit-env)
        shift; edit_env_command "$@";;
    help|*)
        usage;;
esac
