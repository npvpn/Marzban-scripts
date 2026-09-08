#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

EXPORT_DIR="${1:-}"
if [[ -z "$EXPORT_DIR" || ! -d "$EXPORT_DIR" ]]; then
  echo "Usage: $0 <pg_export_dir_from_02_pg_export_source>" >&2
  exit 2
fi

RUN_ID="${RUN_ID:-$(timestamp)}"
OUT_DIR="$ARTIFACT_ROOT/$RUN_ID/marzban_normalize"
mkdir -p "$OUT_DIR"

PANEL_REF="${PANEL_USER}@${PANEL_HOST}"

panel_mysql_env_file="$OUT_DIR/panel_mysql_env.txt"
remote_panel_mysql_env > "$panel_mysql_env_file"
panel_mysql_db="$(awk -F= '$1=="MYSQL_DATABASE"{print $2}' "$panel_mysql_env_file")"
require_partner_multibot_schema "$panel_mysql_db"
HAS_SOURCE_BOT_ID=0
if [[ "$(mysql_column_exists "$PANEL_REF" "$PANEL_MYSQL_CONTAINER" "$panel_mysql_db" "bots" "source_bot_id")" == "1" ]]; then
  HAS_SOURCE_BOT_ID=1
fi

echo "Building partner-panel normalization SQL from PG export"
python3 - "$EXPORT_DIR" "$OUT_DIR/panel_normalize.sql" "$TARGET_BOT_USERNAME" "$TARGET_BOT_ID" "${HAS_SOURCE_BOT_ID:-0}" <<'PY'
import csv
import sys
from pathlib import Path

export_dir, out_path, bot_username, target_bot_id, has_source_bot_id = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]

types = {}
with open(export_dir / "subscriptions_type.csv", newline="") as f:
    for row in csv.DictReader(f):
        types[row["id"]] = row.get("devices_limit") or ""

desired = []
with open(export_dir / "subscriptions.csv", newline="") as f:
    for row in csv.DictReader(f):
        tg = int(row["tg_user_id"])
        sub_id = int(row["id"])
        username = f"w{abs(tg)}_{sub_id}" if tg < 0 else f"{tg}_{sub_id}"
        desired.append((username, types.get(row["sub_type_id"], "")))

def sql_str(value):
    return "'" + str(value).replace("'", "''") + "'"

source_sql = ""
source_val = ""
source_update = ""
if has_source_bot_id == "1" and str(target_bot_id).isdigit():
    source_sql = ", source_bot_id"
    source_val = f", {target_bot_id}"
    source_update = ", source_bot_id=VALUES(source_bot_id)"

with out_path.open("w", encoding="utf-8") as w:
    w.write("START TRANSACTION;\n")
    w.write(
        f"INSERT INTO bots (username, title, created_at, updated_at{source_sql}) VALUES ({sql_str(bot_username)}, {sql_str(bot_username)}, NOW(), NOW(){source_val}) "
        f"ON DUPLICATE KEY UPDATE title=VALUES(title), updated_at=NOW(){source_update};\n"
    )
    w.write(f"SET @bot_id := (SELECT id FROM bots WHERE username={sql_str(bot_username)} LIMIT 1);\n")
    w.write("CREATE TEMPORARY TABLE st_desired_users(username varchar(255) primary key, device_limit int null);\n")
    for username, device_limit in desired:
        limit_sql = "NULL" if device_limit in {"", "NULL"} else str(int(device_limit))
        w.write(f"INSERT INTO st_desired_users(username, device_limit) VALUES ({sql_str(username)}, {limit_sql});\n")
    w.write(
        "UPDATE users u "
        "JOIN st_desired_users s ON s.username=u.username "
        "SET u.bot_id=@bot_id, "
        "    u.device_limit=COALESCE(s.device_limit, u.device_limit);\n"
    )
    w.write(
        "INSERT INTO bot_settings (bot_id, data, created_at, updated_at) "
        "SELECT @bot_id, JSON_OBJECT(), NOW(), NOW() "
        "WHERE NOT EXISTS (SELECT 1 FROM bot_settings WHERE bot_id=@bot_id);\n"
    )
    w.write("COMMIT;\n")
    w.write("SELECT 'users_bound_to_bot' AS metric, COUNT(*) AS value FROM users WHERE bot_id=@bot_id;\n")
    w.write(
        "SELECT 'missing_tokens' AS metric, COUNT(*) AS value FROM users WHERE bot_id=@bot_id AND (subscription_token IS NULL OR subscription_token='');\n"
    )
    w.write(
        "SELECT 'users_without_proxy' AS metric, COUNT(*) AS value "
        "FROM users u LEFT JOIN proxies p ON p.user_id=u.id WHERE u.bot_id=@bot_id AND p.id IS NULL;\n"
    )
    w.write(
        "SELECT 'host_associations' AS metric, COUNT(*) AS value FROM host_bot_association WHERE bot_id=@bot_id;\n"
    )
PY

echo "Applying partner-panel normalization on source host"
run_ssh "$PANEL_REF" "docker exec -i '$PANEL_MYSQL_CONTAINER' sh -lc 'if [ -n \"\${MYSQL_ROOT_PASSWORD:-}\" ]; then mysql --default-character-set=utf8mb4 -uroot -p\"\$MYSQL_ROOT_PASSWORD\" \"$panel_mysql_db\"; else mysql --default-character-set=utf8mb4 \"$panel_mysql_db\"; fi'" \
  < "$OUT_DIR/panel_normalize.sql" | tee "$OUT_DIR/panel_normalize_result.txt"

echo "Partner-panel normalization complete: $OUT_DIR"
