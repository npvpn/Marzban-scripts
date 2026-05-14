#!/bin/bash

# Параллельная миграция нод через официальный marzban-node.sh.
# migrate подключает watchtower (авто-обновление ноды) и поднимает лимиты nf_conntrack.
#
# IP-адреса берутся из файла (по одному на строку).
# Логи по каждой ноде складываются в ./migrate-logs/<ip>.log.
#
# Перед использованием: chmod +x migrate_nodes.sh
# На всех нодах должен быть добавлен SSH-ключ от машины, с которой запускается скрипт.
#
# Использование:
#   ./migrate_nodes.sh                           # nodes.txt в той же папке, 20 параллельно
#   ./migrate_nodes.sh /path/to/nodes.txt        # явный путь
#   ./migrate_nodes.sh nodes.txt 50              # 50 параллельных подключений

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODES_FILE="${1:-$SCRIPT_DIR/nodes.txt}"
PARALLEL="${2:-20}"
LOG_DIR="$SCRIPT_DIR/migrate-logs"

if [[ ! -f "$NODES_FILE" ]]; then
    echo "Файл не найден: $NODES_FILE"
    echo "Создайте файл с IP-адресами (по одному на строку)"
    exit 1
fi

mkdir -p "$LOG_DIR"

REMOTE_CMD='bash -c "$(curl -fsSL https://github.com/npvpn/Marzban-scripts/raw/master/marzban-node.sh)" @ migrate'

run_one() {
    local ip="$1"
    local log="$LOG_DIR/$ip.log"

    if ssh -o StrictHostKeyChecking=accept-new \
           -o BatchMode=yes \
           -o ConnectTimeout=10 \
           root@"$ip" "$REMOTE_CMD" </dev/null >"$log" 2>&1 \
       && grep -q "Migration complete" "$log"; then
        echo "OK   $ip"
    else
        echo "FAIL $ip   (см. $log)"
    fi
}
export -f run_one
export LOG_DIR REMOTE_CMD

# Чистим список: убираем пробелы, пустые строки, комментарии.
grep -v '^[[:space:]]*\(#\|$\)' "$NODES_FILE" \
    | tr -d '[:blank:]' \
    | xargs -I{} -P "$PARALLEL" -n 1 bash -c 'run_one "$@"' _ {}

echo
echo "Готово. Логи: $LOG_DIR"
echo "Ноды, где миграция не завершилась успехом:"
grep -L "Migration complete" "$LOG_DIR"/*.log 2>/dev/null || echo "  (нет — все прошли)"
