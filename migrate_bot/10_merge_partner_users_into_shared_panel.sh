#!/usr/bin/env bash
# Scenario C: merge one partner bot's Marzban users into the live shared panel.
# SOURCE_* + MYSQL_CONTAINER = old partner panel. PANEL_* = platform nvb_mysql.
# Does NOT truncate destination tables. Do not use 09 for this topology.
# Does not write host_bot_association: location allowlists stay as they were.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

TRANSFORM_PY="$SCRIPT_DIR/10_merge_partner_users.py"
DRY_RUN="${DRY_RUN:-false}"

: "${PANEL_PATH:?Set PANEL_PATH to the platform panel path before step 10}"
: "${PANEL_MYSQL_CONTAINER:?Set PANEL_MYSQL_CONTAINER to the platform MySQL container (nvb_mysql)}"
: "${PANEL_ENV_FILE:?}"

if [[ ! -s "$TRANSFORM_PY" ]]; then
  echo "Missing transform helper: $TRANSFORM_PY" >&2
  exit 2
fi

if [[ "$SOURCE_HOST" == "$PANEL_HOST" && "$MYSQL_CONTAINER" == "$PANEL_MYSQL_CONTAINER" ]]; then
  echo "SOURCE MySQL and PANEL MySQL are the same container. Refusing to merge a panel into itself." >&2
  echo "For scenario C: MYSQL_CONTAINER=partner MySQL, PANEL_MYSQL_CONTAINER=nvb_mysql on the platform." >&2
  exit 2
fi

ensure_artifacts
RUN_ID="${RUN_ID:-$(timestamp)}"
OUT_DIR="$ARTIFACT_ROOT/$RUN_ID/panel_merge"
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

SOURCE_REF="${SOURCE_USER}@${SOURCE_HOST}"
PANEL_REF="${PANEL_USER}@${PANEL_HOST}"
TARGET_REF="${TARGET_USER}@${TARGET_HOST}"

docker_container_running() {
  local host_ref="$1"
  local container="$2"
  run_ssh "$host_ref" "docker inspect -f '{{.State.Running}}' '$container' 2>/dev/null || echo false" \
    | tr -d '\r' | awk 'NF{print; exit}'
}

mysql_query() {
  local host_ref="$1"
  local mysql_container="$2"
  local mysql_db="$3"
  run_ssh "$host_ref" "docker exec -i '$mysql_container' sh -lc 'if [ -n \"\${MYSQL_ROOT_PASSWORD:-}\" ]; then mysql --default-character-set=utf8mb4 -uroot -p\"\$MYSQL_ROOT_PASSWORD\" \"$mysql_db\"; else mysql --default-character-set=utf8mb4 \"$mysql_db\"; fi'"
}

mysql_query_raw() {
  local host_ref="$1"
  local mysql_container="$2"
  local mysql_db="$3"
  run_ssh "$host_ref" "docker exec -i '$mysql_container' sh -lc 'if [ -n \"\${MYSQL_ROOT_PASSWORD:-}\" ]; then mysql --default-character-set=utf8mb4 -N -B --raw -uroot -p\"\$MYSQL_ROOT_PASSWORD\" \"$mysql_db\"; else mysql --default-character-set=utf8mb4 -N -B --raw \"$mysql_db\"; fi'"
}

mysql_column_names() {
  local host_ref="$1"
  local mysql_container="$2"
  local mysql_db="$3"
  local table_name="$4"
  local mysql_db_sql="${mysql_db//\'/\'\'}"
  local table_name_sql="${table_name//\'/\'\'}"
  printf '%s\n' \
    "SELECT COLUMN_NAME FROM information_schema.columns WHERE table_schema='${mysql_db_sql}' AND table_name='${table_name_sql}' ORDER BY ORDINAL_POSITION;" \
    | mysql_query_raw "$host_ref" "$mysql_container" "$mysql_db" \
    | tr -d '\r'
}

json_object_pairs() {
  local cols_file="$1"
  local pairs=()
  local col
  while IFS= read -r col; do
    [[ -n "$col" ]] || continue
    pairs+=("'${col}', \`${col}\`")
  done < "$cols_file"
  local IFS=', '
  printf '%s' "${pairs[*]}"
}

dump_jsonl() {
  local host_ref="$1"
  local mysql_container="$2"
  local mysql_db="$3"
  local table_name="$4"
  local cols_file="$5"
  local where_sql="$6"
  local out_file="$7"
  if [[ ! -s "$cols_file" ]]; then
    : > "$out_file"
    return 0
  fi
  local pairs
  pairs="$(json_object_pairs "$cols_file")"
  printf 'SELECT JSON_OBJECT(%s) FROM `%s` %s;\n' "$pairs" "$table_name" "$where_sql" \
    | mysql_query_raw "$host_ref" "$mysql_container" "$mysql_db" \
    | tr -d '\r' > "$out_file"
}

wait_dest_mysql_ready() {
  local attempts="${1:-30}"
  local i
  for ((i = 1; i <= attempts; i++)); do
    if [[ "$(docker_container_running "$PANEL_REF" "$PANEL_MYSQL_CONTAINER")" == "true" ]]; then
      if run_panel_ssh "docker exec '$PANEL_MYSQL_CONTAINER' sh -lc 'if [ -n \"\${MYSQL_ROOT_PASSWORD:-}\" ]; then mysqladmin ping -h 127.0.0.1 -uroot -p\"\$MYSQL_ROOT_PASSWORD\" --silent; else mysqladmin ping -h 127.0.0.1 --silent; fi'" >/dev/null 2>&1; then
        echo "Destination MySQL is ready (${PANEL_MYSQL_CONTAINER})"
        return 0
      fi
    fi
    echo "Waiting for destination MySQL (${i}/${attempts})..."
    sleep 2
  done
  echo "Destination MySQL did not become ready: ${PANEL_MYSQL_CONTAINER}" >&2
  return 1
}

restart_destination_panel() {
  echo "Restarting destination MySQL (${PANEL_MYSQL_CONTAINER}) so the panel reloads merged users"
  run_panel_ssh "docker restart '$PANEL_MYSQL_CONTAINER'"
  wait_dest_mysql_ready 30

  echo "Restarting destination panel so Xray and env pick up merged users"
  if run_panel_ssh "command -v marzban >/dev/null 2>&1"; then
    run_panel_ssh "cd '${PANEL_PATH}' && marzban restart -n"
    return 0
  fi
  if run_panel_ssh "cd '${PANEL_PATH}' && docker compose restart marzban >/dev/null 2>&1"; then
    return 0
  fi
  run_panel_ssh "docker restart nvb_marz"
}

append_legacy_jwt_secret() {
  local secret="$1"
  if [[ -z "$secret" ]]; then
    echo "Warning: source JWT secret was not found; PANEL_ENV_FILE was not changed" >&2
    echo "Add it manually to ${PANEL_ENV_FILE} as SUBSCRIPTION_LEGACY_SECRET_KEYS and restart the panel." >&2
    return 0
  fi
  echo "Writing SUBSCRIPTION_LEGACY_SECRET_KEYS to ${PANEL_ENV_FILE}"
  run_panel_ssh "python3 - '$PANEL_ENV_FILE' '$secret'" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
secret = sys.argv[2].strip()
lines = path.read_text(errors="ignore").splitlines() if path.exists() else []
key = "SUBSCRIPTION_LEGACY_SECRET_KEYS"
found = False
out = []
for line in lines:
    if line.startswith(key + "="):
        found = True
        current = line.split("=", 1)[1].strip().strip('"').strip("'")
        values = [item.strip() for item in current.split(",") if item.strip()]
        if secret not in values:
            values.append(secret)
        out.append(key + "=" + ",".join(values))
    else:
        out.append(line)
if not found:
    out.append(key + "=" + secret)
path.write_text("\n".join(out) + "\n")
PY
}

clear_target_bot_domain() {
  local pg_user="$1"
  local pg_db="$2"
  echo "Clearing bots.domain on target PG for bot_id=${TARGET_BOT_ID}"
  run_ssh "$TARGET_REF" "docker exec -i '$PG_CONTAINER' psql -v ON_ERROR_STOP=1 -U '$pg_user' -d '$pg_db'" >/dev/null <<SQL
UPDATE bots SET domain = NULL WHERE id = ${TARGET_BOT_ID};
SQL
}

echo "=== Scenario C merge: partner users -> shared panel ==="
echo "Run: $RUN_ID"
echo "Dump from ${SOURCE_REF} container ${MYSQL_CONTAINER}"
echo "Insert into ${PANEL_REF} container ${PANEL_MYSQL_CONTAINER}"
echo "DRY_RUN=${DRY_RUN}"

probe_ssh "$SOURCE_REF" "source panel"
probe_ssh "$PANEL_REF" "destination panel"

if [[ "$(docker_container_running "$SOURCE_REF" "$MYSQL_CONTAINER")" != "true" ]]; then
  echo "Source MySQL container is not running: $MYSQL_CONTAINER" >&2
  echo "SSH works, but docker inspect did not return true. Check 'docker ps' on ${SOURCE_REF}." >&2
  exit 2
fi
if [[ "$(docker_container_running "$PANEL_REF" "$PANEL_MYSQL_CONTAINER")" != "true" ]]; then
  echo "Destination panel MySQL container is not running: $PANEL_MYSQL_CONTAINER" >&2
  echo "SSH works, but docker inspect did not return true. Check 'docker ps' on ${PANEL_REF}." >&2
  exit 2
fi

remote_mysql_env "$SOURCE_REF" "$MYSQL_CONTAINER" > "$OUT_DIR/source_mysql_env.txt"
remote_panel_mysql_env > "$OUT_DIR/panel_mysql_env.txt"
source_mysql_db="$(awk -F= '$1=="MYSQL_DATABASE"{print $2}' "$OUT_DIR/source_mysql_env.txt")"
panel_mysql_db="$(awk -F= '$1=="MYSQL_DATABASE"{print $2}' "$OUT_DIR/panel_mysql_env.txt")"

if [[ -z "$source_mysql_db" || -z "$panel_mysql_db" ]]; then
  echo "Failed to detect MySQL database names" >&2
  exit 7
fi

require_partner_multibot_schema "$panel_mysql_db"

source_has_bots="$(mysql_table_exists "$SOURCE_REF" "$MYSQL_CONTAINER" "$source_mysql_db" "bots")"
source_has_bot_settings="$(mysql_table_exists "$SOURCE_REF" "$MYSQL_CONTAINER" "$source_mysql_db" "bot_settings")"
source_has_next_plans="$(mysql_table_exists "$SOURCE_REF" "$MYSQL_CONTAINER" "$source_mysql_db" "next_plans")"
source_has_devices="$(mysql_table_exists "$SOURCE_REF" "$MYSQL_CONTAINER" "$source_mysql_db" "user_devices")"
source_has_jwt="$(mysql_table_exists "$SOURCE_REF" "$MYSQL_CONTAINER" "$source_mysql_db" "jwt")"
dest_has_next_plans="$(panel_mysql_table_exists "$panel_mysql_db" "next_plans")"
dest_has_devices="$(panel_mysql_table_exists "$panel_mysql_db" "user_devices")"

mysql_column_names "$SOURCE_REF" "$MYSQL_CONTAINER" "$source_mysql_db" "users" > "$OUT_DIR/source_users_columns.txt"
mysql_column_names "$SOURCE_REF" "$MYSQL_CONTAINER" "$source_mysql_db" "proxies" > "$OUT_DIR/source_proxies_columns.txt"
mysql_column_names "$PANEL_REF" "$PANEL_MYSQL_CONTAINER" "$panel_mysql_db" "users" > "$OUT_DIR/dest_users_columns.txt"
mysql_column_names "$PANEL_REF" "$PANEL_MYSQL_CONTAINER" "$panel_mysql_db" "proxies" > "$OUT_DIR/dest_proxies_columns.txt"

if [[ "$dest_has_next_plans" == "1" ]]; then
  mysql_column_names "$PANEL_REF" "$PANEL_MYSQL_CONTAINER" "$panel_mysql_db" "next_plans" > "$OUT_DIR/dest_next_plan_columns.txt"
else
  : > "$OUT_DIR/dest_next_plan_columns.txt"
fi
if [[ "$dest_has_devices" == "1" ]]; then
  mysql_column_names "$PANEL_REF" "$PANEL_MYSQL_CONTAINER" "$panel_mysql_db" "user_devices" > "$OUT_DIR/dest_device_columns.txt"
else
  : > "$OUT_DIR/dest_device_columns.txt"
fi
if [[ "$source_has_next_plans" == "1" ]]; then
  mysql_column_names "$SOURCE_REF" "$MYSQL_CONTAINER" "$source_mysql_db" "next_plans" > "$OUT_DIR/source_next_plan_columns.txt"
else
  : > "$OUT_DIR/source_next_plan_columns.txt"
fi
if [[ "$source_has_devices" == "1" ]]; then
  mysql_column_names "$SOURCE_REF" "$MYSQL_CONTAINER" "$source_mysql_db" "user_devices" > "$OUT_DIR/source_device_columns.txt"
else
  : > "$OUT_DIR/source_device_columns.txt"
fi

users_where=""
if [[ "$source_has_bots" == "1" ]]; then
  source_bot_id="$(
    printf "SELECT id FROM bots WHERE username=%s LIMIT 1;\n" "'${SOURCE_BOT_USERNAME//\'/\'\'}'" \
      | mysql_query_raw "$SOURCE_REF" "$MYSQL_CONTAINER" "$source_mysql_db" | tr -d '\r' | awk 'NF{print; exit}'
  )"
  if [[ -z "$source_bot_id" && "$SOURCE_BOT_USERNAME" != "$TARGET_BOT_USERNAME" ]]; then
    source_bot_id="$(
      printf "SELECT id FROM bots WHERE username=%s LIMIT 1;\n" "'${TARGET_BOT_USERNAME//\'/\'\'}'" \
        | mysql_query_raw "$SOURCE_REF" "$MYSQL_CONTAINER" "$source_mysql_db" | tr -d '\r' | awk 'NF{print; exit}'
    )"
  fi
  if [[ -z "$source_bot_id" ]]; then
    echo "Bot '${SOURCE_BOT_USERNAME}' not found in source panel bots table" >&2
    exit 8
  fi
  echo "Source bot_id=${source_bot_id}"
  printf '%s\n' "$source_bot_id" > "$OUT_DIR/source_bot_id.txt"
  users_where="WHERE bot_id=${source_bot_id}"
else
  echo "Source panel schema is legacy (no bots table); dumping all users"
  users_where=""
fi

echo "Dumping source users/proxies for one bot (no hosts/inbounds/nodes)"
dump_jsonl "$SOURCE_REF" "$MYSQL_CONTAINER" "$source_mysql_db" "users" \
  "$OUT_DIR/source_users_columns.txt" "$users_where" "$OUT_DIR/source_users.jsonl"

if [[ -n "$users_where" ]]; then
  proxies_where="WHERE user_id IN (SELECT id FROM users ${users_where})"
else
  proxies_where=""
fi
dump_jsonl "$SOURCE_REF" "$MYSQL_CONTAINER" "$source_mysql_db" "proxies" \
  "$OUT_DIR/source_proxies_columns.txt" "$proxies_where" "$OUT_DIR/source_proxies.jsonl"

if [[ "$source_has_next_plans" == "1" && -s "$OUT_DIR/source_next_plan_columns.txt" ]]; then
  dump_jsonl "$SOURCE_REF" "$MYSQL_CONTAINER" "$source_mysql_db" "next_plans" \
    "$OUT_DIR/source_next_plan_columns.txt" \
    "WHERE user_id IN (SELECT id FROM users ${users_where})" \
    "$OUT_DIR/source_next_plans.jsonl"
else
  : > "$OUT_DIR/source_next_plans.jsonl"
fi

if [[ "$source_has_devices" == "1" && -s "$OUT_DIR/source_device_columns.txt" ]]; then
  dump_jsonl "$SOURCE_REF" "$MYSQL_CONTAINER" "$source_mysql_db" "user_devices" \
    "$OUT_DIR/source_device_columns.txt" \
    "WHERE user_id IN (SELECT id FROM users ${users_where})" \
    "$OUT_DIR/source_user_devices.jsonl"
else
  : > "$OUT_DIR/source_user_devices.jsonl"
fi

: > "$OUT_DIR/source_bot_settings.json"
if [[ "$source_has_bot_settings" == "1" ]]; then
  if [[ "$source_has_bots" == "1" ]]; then
    printf "SELECT CAST(data AS JSON) FROM bot_settings WHERE bot_id=%s LIMIT 1;\n" "${source_bot_id}" \
      | mysql_query_raw "$SOURCE_REF" "$MYSQL_CONTAINER" "$source_mysql_db" \
      | tr -d '\r' > "$OUT_DIR/source_bot_settings.json"
  else
    printf '%s\n' "SELECT CAST(data AS JSON) FROM bot_settings LIMIT 1;" \
      | mysql_query_raw "$SOURCE_REF" "$MYSQL_CONTAINER" "$source_mysql_db" \
      | tr -d '\r' > "$OUT_DIR/source_bot_settings.json"
  fi
fi
if [[ ! -s "$OUT_DIR/source_bot_settings.json" ]]; then
  echo '{}' > "$OUT_DIR/source_bot_settings.json"
fi

: > "$OUT_DIR/source_jwt_secret.txt"
if [[ "$source_has_jwt" == "1" ]]; then
  printf '%s\n' "SELECT secret_key FROM jwt LIMIT 1;" \
    | mysql_query_raw "$SOURCE_REF" "$MYSQL_CONTAINER" "$source_mysql_db" \
    | tr -d '\r' | awk 'NF{print; exit}' > "$OUT_DIR/source_jwt_secret.txt"
fi

printf '%s\n' "SELECT DISTINCT type FROM proxies;" \
  | mysql_query_raw "$PANEL_REF" "$PANEL_MYSQL_CONTAINER" "$panel_mysql_db" \
  | tr -d '\r' > "$OUT_DIR/dest_proxy_types.txt"
if [[ "$(panel_mysql_table_exists "$panel_mysql_db" "inbounds")" == "1" ]]; then
  printf '%s\n' "SELECT tag FROM inbounds;" \
    | mysql_query_raw "$PANEL_REF" "$PANEL_MYSQL_CONTAINER" "$panel_mysql_db" \
    | tr -d '\r' > "$OUT_DIR/dest_inbound_tags.txt"
else
  : > "$OUT_DIR/dest_inbound_tags.txt"
fi

python3 - "$OUT_DIR/source_users.jsonl" "$OUT_DIR/src_usernames.sql" <<'PY'
import json, sys
from pathlib import Path

users_path, out_path = Path(sys.argv[1]), Path(sys.argv[2])
usernames = []
if users_path.is_file() and users_path.stat().st_size:
    for line in users_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        username = str(json.loads(line).get("username") or "").strip()
        if username:
            usernames.append(username.replace("\\", "\\\\").replace("'", "''"))
lines = ["CREATE TEMPORARY TABLE st_src_usernames(username varchar(255) primary key);"]
for username in usernames:
    lines.append(f"INSERT INTO st_src_usernames(username) VALUES ('{username}');")
lines.append(
    "SELECT JSON_OBJECT('username', u.username, 'bot_id', u.bot_id, 'bot_username', b.username) "
    "FROM users u JOIN st_src_usernames s ON s.username = u.username "
    "LEFT JOIN bots b ON b.id = u.bot_id;"
)
out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"source_usernames={len(usernames)}")
PY

: > "$OUT_DIR/dest_existing.jsonl"
if [[ -s "$OUT_DIR/src_usernames.sql" ]]; then
  mysql_query_raw "$PANEL_REF" "$PANEL_MYSQL_CONTAINER" "$panel_mysql_db" \
    < "$OUT_DIR/src_usernames.sql" | tr -d '\r' > "$OUT_DIR/dest_existing.jsonl"
fi

source_user_count="$(wc -l < "$OUT_DIR/source_users.jsonl" | tr -d ' ')"
if [[ "$source_user_count" == "0" ]]; then
  echo "No source users dumped. Check SOURCE_BOT_USERNAME / MYSQL_CONTAINER." >&2
  exit 9
fi

set +e
python3 "$TRANSFORM_PY" \
  --target-bot-username "$TARGET_BOT_USERNAME" \
  --source-users "$OUT_DIR/source_users.jsonl" \
  --source-proxies "$OUT_DIR/source_proxies.jsonl" \
  --source-next-plans "$OUT_DIR/source_next_plans.jsonl" \
  --source-devices "$OUT_DIR/source_user_devices.jsonl" \
  --source-bot-settings "$OUT_DIR/source_bot_settings.json" \
  --dest-existing "$OUT_DIR/dest_existing.jsonl" \
  --dest-user-columns "$OUT_DIR/dest_users_columns.txt" \
  --dest-next-plan-columns "$OUT_DIR/dest_next_plan_columns.txt" \
  --dest-device-columns "$OUT_DIR/dest_device_columns.txt" \
  --dest-proxy-types "$OUT_DIR/dest_proxy_types.txt" \
  --dest-inbound-tags "$OUT_DIR/dest_inbound_tags.txt" \
  --out-sql "$OUT_DIR/apply.sql" \
  --out-report "$OUT_DIR/report.json" \
  --out-settings "$OUT_DIR/filtered_bot_settings.json"
transform_rc=$?
set -e

if [[ "$transform_rc" -eq 4 ]]; then
  echo "Abort: username collisions with another bot on the shared panel." >&2
  echo "See $OUT_DIR/report.json" >&2
  exit 4
fi
if [[ "$transform_rc" -ne 0 ]]; then
  echo "Transform failed with exit $transform_rc" >&2
  exit "$transform_rc"
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY_RUN=true: SQL written to $OUT_DIR/apply.sql, destination not changed"
  echo "Report: $OUT_DIR/report.json"
  exit 0
fi

echo "Applying merge SQL on destination panel MySQL (no TRUNCATE)"
mysql_query "$PANEL_REF" "$PANEL_MYSQL_CONTAINER" "$panel_mysql_db" \
  < "$OUT_DIR/apply.sql" | tee "$OUT_DIR/apply_result.txt"

legacy_secret="$(tr -d '\r' < "$OUT_DIR/source_jwt_secret.txt" | awk 'NF{print; exit}')"
append_legacy_jwt_secret "$legacy_secret"

if [[ "${SKIP_TARGET_PG:-false}" == "true" ]]; then
  echo "SKIP_TARGET_PG=true: not touching target PostgreSQL (bots.domain)"
else
  target_pg_env_file="$OUT_DIR/target_pg_env.txt"
  remote_pg_env "$TARGET_REF" "$PG_CONTAINER" > "$target_pg_env_file"
  pg_user="$(awk -F= '$1=="PGUSER"{print $2}' "$target_pg_env_file")"
  pg_db="$(awk -F= '$1=="PGDATABASE"{print $2}' "$target_pg_env_file")"
  clear_target_bot_domain "$pg_user" "$pg_db"
fi

restart_destination_panel

echo "Merge complete: $OUT_DIR"
echo "Next: ./06_verify_cutover_checks.sh  (PANEL_* must stay on the shared platform panel)"
echo "Do not run 08/09 for this topology."
