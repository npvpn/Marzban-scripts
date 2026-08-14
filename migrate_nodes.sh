#!/bin/bash

# Параллельная миграция нод через официальный marzban-node.sh.
# migrate подключает watchtower (авто-обновление ноды), поднимает лимиты
# nf_conntrack, ставит node_exporter и открывает :9100 только для IP бота
# (Prometheus на платформе).
#
# IP-адреса берутся из файла (по одному на строку).
# Логи по каждой ноде складываются в ./migrate-logs/<ip>.log.
#
# Перед использованием: chmod +x migrate_nodes.sh
# На всех нодах должен быть добавлен SSH-ключ от машины, с которой запускается скрипт.
#
# Использование:
#   ./migrate_nodes.sh nodes.txt 20 1.2.3.4          # файл, параллельность, IP бота
#   BOT_SERVER_IP=1.2.3.4 ./migrate_nodes.sh         # nodes.txt, 20 параллельно
#   ./migrate_nodes.sh /path/to/nodes.txt 50 1.2.3.4
#
# Третий аргумент / BOT_SERVER_IP — публичный IPv4 сервера бота (Prometheus).
# Обязателен: :9100 открывается только для этого IP.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODES_FILE="${1:-$SCRIPT_DIR/nodes.txt}"
PARALLEL="${2:-20}"
BOT_SERVER_IP="${3:-${BOT_SERVER_IP:-}}"
LOG_DIR="$SCRIPT_DIR/migrate-logs"
SCRIPT_URL="${MARZBAN_NODE_SCRIPT_URL:-https://github.com/npvpn/Marzban-scripts/raw/master/marzban-node.sh}"

if [[ ! -f "$NODES_FILE" ]]; then
    echo "Файл не найден: $NODES_FILE"
    echo "Создайте файл с IP-адресами (по одному на строку)"
    exit 1
fi

if [[ -z "$BOT_SERVER_IP" ]]; then
    echo "Нужен публичный IPv4 сервера бота/Prometheus (чтобы открыть :9100 только ему)."
    echo "  ./migrate_nodes.sh nodes.txt 20 1.2.3.4"
    echo "или BOT_SERVER_IP=1.2.3.4 ./migrate_nodes.sh"
    exit 1
fi

if [[ ! "$BOT_SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "Некорректный IPv4 бота: $BOT_SERVER_IP"
    exit 1
fi

mkdir -p "$LOG_DIR"

REMOTE_CMD="bash -c \"\$(curl -fsSL ${SCRIPT_URL})\" @ migrate --bot-server-ip ${BOT_SERVER_IP}"

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
