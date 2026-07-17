#!/usr/bin/env bash
set -euo pipefail

# Target-only repair: restore Marzban users.created_at from local pg_export so legacy
# /sub/<token> links keep working after migration. Does not require source server access.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

EXPORT_DIR="${1:-}"
if [[ -z "$EXPORT_DIR" || ! -d "$EXPORT_DIR" ]]; then
  echo "Usage: $0 <pg_export_dir_from_02_pg_export_source>" >&2
  exit 2
fi

RUN_ID="${RUN_ID:-$(timestamp)}"
OUT_DIR="$ARTIFACT_ROOT/$RUN_ID/panel_repair"
mkdir -p "$OUT_DIR"

PANEL_REF="${PANEL_USER}@${PANEL_HOST}"
panel_mysql_env_file="$OUT_DIR/panel_mysql_env.txt"
remote_panel_mysql_env > "$panel_mysql_env_file"
panel_mysql_db="$(awk -F= '$1=="MYSQL_DATABASE"{print $2}' "$panel_mysql_env_file")"
require_partner_multibot_schema "$panel_mysql_db"

python3 - "$EXPORT_DIR" "$OUT_DIR/target_repair.sql" "$TARGET_BOT_USERNAME" <<'PY'
import csv, sys
from datetime import datetime
from pathlib import Path

export_dir, out_path, bot_username = Path(sys.argv[1]), sys.argv[2], sys.argv[3]

users_by_tg = {}
with open(export_dir / "users.csv", newline="") as f:
    for row in csv.DictReader(f):
        users_by_tg[int(row["tg_user_id"])] = row["created_at"]

def parse_dt(value: str) -> datetime | None:
    if not value:
        return None
    text = value.replace("T", " ").split(".")[0].strip()
    for fmt in ("%Y-%m-%d %H:%M:%S%z", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d"):
        try:
            return datetime.strptime(text, fmt)
        except ValueError:
            pass
    return None

def sql_str(v):
    return "'" + str(v).replace("'", "''") + "'"

rows = []
with open(export_dir / "subscriptions.csv", newline="") as f:
    for row in csv.DictReader(f):
        tg = int(row["tg_user_id"])
        sub_id = int(row["id"])
        username = f"w{abs(tg)}_{sub_id}" if tg < 0 else f"{tg}_{sub_id}"
        candidates = [parse_dt(row.get("created_at", "")), parse_dt(users_by_tg.get(tg, ""))]
        candidates = [dt for dt in candidates if dt is not None]
        if not candidates:
            continue
        created_at = min(candidates).strftime("%Y-%m-%d %H:%M:%S")
        rows.append((username, created_at))

with open(out_path, "w") as w:
    w.write("START TRANSACTION;\n")
    w.write("""
CREATE TEMPORARY TABLE st_repair(
  username varchar(255) primary key,
  created_at datetime not null
);
""")
    for username, created_at in rows:
        w.write(
            "INSERT INTO st_repair VALUES ("
            f"{sql_str(username)},{sql_str(created_at)}"
            ");\n"
        )
    w.write(f"""
SET @bot_id := (SELECT id FROM bots WHERE username = {sql_str(bot_username)} LIMIT 1);

UPDATE users u
JOIN st_repair s ON s.username = u.username
SET u.created_at = s.created_at,
    u.last_status_change = u.last_status_change
WHERE u.bot_id = @bot_id
  AND (u.created_at IS NULL OR u.created_at > s.created_at);

COMMIT;

SELECT 'updated_users' AS metric, COUNT(*) AS value
FROM users u
JOIN st_repair s ON s.username = u.username
WHERE u.bot_id = @bot_id
  AND u.created_at = s.created_at;

SELECT 'still_too_new_created_at' AS metric, COUNT(*) AS value
FROM users u
JOIN st_repair s ON s.username = u.username
WHERE u.bot_id = @bot_id
  AND u.created_at > s.created_at;
""")
print(f"prepared_rows={len(rows)}")
PY

echo "Applying created_at repair on source partner panel (from pg_export only)"
run_ssh "$PANEL_REF" "docker exec -i '$PANEL_MYSQL_CONTAINER' sh -lc 'if [ -n \"\${MYSQL_ROOT_PASSWORD:-}\" ]; then mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" \"$panel_mysql_db\"; else mysql \"$panel_mysql_db\"; fi'" \
  < "$OUT_DIR/target_repair.sql" | tee "$OUT_DIR/target_repair_result.txt"

echo "Restarting partner panel service"
run_ssh "$PANEL_REF" "cd '$PANEL_PATH' && docker compose restart marzban" >/dev/null

echo "Verifying sample legacy subscription user 7121704831_849"
run_ssh "$PANEL_REF" "docker exec -i '$PANEL_MYSQL_CONTAINER' sh -lc 'if [ -n \"\${MYSQL_ROOT_PASSWORD:-}\" ]; then mysql -N -B -uroot -p\"\$MYSQL_ROOT_PASSWORD\" \"$panel_mysql_db\" -e \"SELECT username, created_at FROM users WHERE username=\\\"7121704831_849\\\" LIMIT 1\"; else mysql -N -B \"$panel_mysql_db\" -e \"SELECT username, created_at FROM users WHERE username=\\\"7121704831_849\\\" LIMIT 1\"; fi'" 2>/dev/null || true

echo "Repair complete: $OUT_DIR"
