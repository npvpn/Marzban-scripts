#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

ensure_artifacts

SOURCE_REF="${SOURCE_USER}@${SOURCE_HOST}"
PANEL_REF="${PANEL_USER}@${PANEL_HOST}"

MYSQL_SWAP_AT_RESTORE="${MYSQL_SWAP_AT_RESTORE:-true}"
LEGACY_MARZBAN_CONTAINER="${LEGACY_MARZBAN_CONTAINER:-}"
RESUME_RUN_ID="${RESUME_RUN_ID:-}"
SKIP_NODE_USAGE_TABLES="${SKIP_NODE_USAGE_TABLES:-false}"
USAGE_SKIP_TABLES=(node_usages node_user_usages)

: "${PANEL_PATH:?Set PANEL_PATH=/opt/marzban in migration.env before step 09}"
: "${PANEL_MYSQL_CONTAINER:?Set PANEL_MYSQL_CONTAINER (partner MySQL container name) before step 09}"

if [[ -n "$RESUME_RUN_ID" ]]; then
  OUT_DIR="$ARTIFACT_ROOT/$RESUME_RUN_ID/mysql_restore"
  if [[ ! -s "$OUT_DIR/source_legacy_data.sql" ]]; then
    echo "Resume dump not found: $OUT_DIR/source_legacy_data.sql" >&2
    exit 2
  fi
  echo "Resume mode: reusing dump from $OUT_DIR"
else
  RUN_ID="${RUN_ID:-$(timestamp)}"
  OUT_DIR="$ARTIFACT_ROOT/$RUN_ID/mysql_restore"
  mkdir -p "$OUT_DIR"
fi

docker_container_running() {
  local host_ref="$1"
  local container="$2"
  run_ssh "$host_ref" "docker inspect -f '{{.State.Running}}' '$container' 2>/dev/null || echo false" \
    | tr -d '\r' | awk 'NF{print; exit}'
}

wait_partner_mysql_ready() {
  local attempts="${1:-60}"
  local i
  for ((i = 1; i <= attempts; i++)); do
    if [[ "$(docker_container_running "$PANEL_REF" "$PANEL_MYSQL_CONTAINER")" == "true" ]]; then
      if run_ssh "$PANEL_REF" "docker exec '$PANEL_MYSQL_CONTAINER' sh -lc 'if [ -n \"\${MYSQL_ROOT_PASSWORD:-}\" ]; then mysqladmin ping -h 127.0.0.1 -uroot -p\"\$MYSQL_ROOT_PASSWORD\" --silent; else mysqladmin ping -h 127.0.0.1 --silent; fi'" >/dev/null 2>&1; then
        echo "Partner MySQL is ready (${PANEL_MYSQL_CONTAINER})"
        return 0
      fi
    fi
    echo "Waiting for partner MySQL (${i}/${attempts})..."
    sleep 5
  done
  echo "Partner MySQL did not become ready: ${PANEL_MYSQL_CONTAINER}" >&2
  return 1
}

is_usage_skip_table() {
  local table="$1"
  local skip
  [[ "$SKIP_NODE_USAGE_TABLES" == "true" ]] || return 1
  for skip in "${USAGE_SKIP_TABLES[@]}"; do
    if [[ "$table" == "$skip" ]]; then
      return 0
    fi
  done
  return 1
}

start_partner_stack() {
  echo "Starting partner panel stack at ${PANEL_PATH}"
  # `marzban up` exits 1 when already running — that used to abort 09 before import.
  if run_panel_ssh "cd '${PANEL_PATH}' && marzban up -n"; then
    return 0
  fi
  echo "Partner stack already up (marzban up non-zero) — continuing"
}

restart_partner_stack() {
  echo "Restarting partner panel at ${PANEL_PATH} so Alembic can create fork schema on :3306"
  run_panel_ssh "cd '${PANEL_PATH}' && marzban restart -n"
}

wait_partner_fork_schema() {
  local mysql_db="$1"
  local attempts="${2:-60}"
  local i
  for ((i = 1; i <= attempts; i++)); do
    if [[ "$(panel_mysql_table_exists "$mysql_db" "admins")" == "1" \
       && "$(panel_mysql_table_exists "$mysql_db" "bots")" == "1" ]]; then
      echo "Partner fork schema is ready (admins + bots)"
      return 0
    fi
    echo "Waiting for partner Alembic schema (${i}/${attempts})..."
    sleep 5
  done
  echo "Partner MySQL still has no fork tables (admins/bots)." >&2
  echo "On source: cd ${PANEL_PATH} && marzban restart" >&2
  echo "Then: RESUME_RUN_ID=${RESUME_RUN_ID:-<RUN_ID>} MYSQL_SWAP_AT_RESTORE=false $0" >&2
  return 1
}

ensure_partner_panel_admin() {
  local mysql_db="$1"
  local count
  count="$(
    printf 'SELECT COUNT(*) FROM admins;\n' \
      | run_mysql "$PANEL_REF" "$mysql_db" "$PANEL_MYSQL_CONTAINER" \
      | tr -d '\r' | awk 'NF && $1 ~ /^[0-9]+$/{print; exit}'
  )"
  if [[ "${count:-0}" != "0" ]]; then
    echo "Partner panel already has ${count} admin row(s)"
    return 0
  fi
  if [[ -z "${PARTNER_ADMIN_USERNAME:-}" || -z "${PARTNER_ADMIN_PASSWORD_HASH:-}" ]]; then
    echo "admins is empty and PARTNER_ADMIN_* is not set — create the panel admin manually" >&2
    return 0
  fi
  echo "Creating partner panel admin ${PARTNER_ADMIN_USERNAME}"
  run_panel_ssh "cd '${PANEL_PATH}' && docker compose exec -T -e CLI_PROG_NAME='marzban cli' -e MARZBAN_ADMIN_PASSWORD='${PARTNER_ADMIN_PASSWORD_HASH}' marzban marzban-cli admin create -u '${PARTNER_ADMIN_USERNAME}' --sudo --telegram-id 0 --discord-webhook ''" \
    || echo "admin create returned non-zero (already exists is ok)"
}

swap_legacy_to_partner_mysql() {
  local legacy_containers=("$MYSQL_CONTAINER")
  if [[ -n "$LEGACY_MARZBAN_CONTAINER" ]]; then
    legacy_containers+=("$LEGACY_MARZBAN_CONTAINER")
  fi

  echo "Stopping legacy stack containers: ${legacy_containers[*]}"
  run_ssh "$SOURCE_REF" "docker stop ${legacy_containers[*]}"

  # After nvb_mysql releases :3306, partner MySQL (host network) can bind it.
  # During 08 both stacks were up, so Marzban often created the admin in *legacy* MySQL
  # and the partner volume stayed empty. Restart runs Alembic against partner MySQL.
  restart_partner_stack
  wait_partner_mysql_ready 60
}

source_mysql_env_file="$OUT_DIR/source_mysql_env.txt"
panel_mysql_env_file="$OUT_DIR/panel_mysql_env.txt"
dump_sql="$OUT_DIR/source_legacy_data.sql"
normalize_sql="$OUT_DIR/partner_post_restore_normalize.sql"
truncate_sql="$OUT_DIR/partner_pre_import_truncate.sql"

if [[ -n "$RESUME_RUN_ID" ]]; then
  echo "=== Phase 1-2: skipped (resume mode) ==="
  if [[ ! -s "$OUT_DIR/source_tables_to_dump.txt" ]]; then
    echo "Missing table list: $OUT_DIR/source_tables_to_dump.txt" >&2
    exit 3
  fi
  if [[ ! -s "$OUT_DIR/source_mysql_columns.json" ]]; then
    echo "Resume dump has no source_mysql_columns.json. Re-run 09 without RESUME_RUN_ID to capture source columns." >&2
    exit 3
  fi
  mapfile -t tables_to_dump < "$OUT_DIR/source_tables_to_dump.txt"
  if [[ "$(docker_container_running "$PANEL_REF" "$PANEL_MYSQL_CONTAINER")" != "true" ]]; then
    start_partner_stack
  fi
  wait_partner_mysql_ready 60
else
  echo "=== Phase 1: dump legacy MySQL (legacy must be running) ==="
  if [[ "$(docker_container_running "$SOURCE_REF" "$MYSQL_CONTAINER")" != "true" ]]; then
    echo "Legacy MySQL container is not running: $MYSQL_CONTAINER" >&2
    echo "Start legacy MySQL before step 09, or resume with:" >&2
    echo "  RESUME_RUN_ID=<RUN_ID> MYSQL_SWAP_AT_RESTORE=false ./09_mysql_full_dump_restore_source_partner.sh" >&2
    exit 2
  fi

  remote_mysql_env "$SOURCE_REF" "$MYSQL_CONTAINER" > "$source_mysql_env_file"
  source_mysql_db="$(awk -F= '$1=="MYSQL_DATABASE"{print $2}' "$source_mysql_env_file")"

  LEGACY_DATA_TABLES=(
    users proxies hosts inbounds nodes jwt tls user_devices
    user_usage_logs node_usages node_user_usages node_user_bs_usage node_user_blocks
    system cascade_routes next_plans user_templates notification_reminders admin_usage_logs
  )

  echo "Detecting legacy data tables on source MySQL"
  tables_to_dump=()
  for table in "${LEGACY_DATA_TABLES[@]}"; do
    if is_usage_skip_table "$table"; then
      echo "Skip usage table $table (SKIP_NODE_USAGE_TABLES=true)"
      continue
    fi
    if [[ "$(mysql_table_exists "$SOURCE_REF" "$MYSQL_CONTAINER" "$source_mysql_db" "$table")" == "1" ]]; then
      tables_to_dump+=("$table")
    fi
  done

  if [[ ${#tables_to_dump[@]} -eq 0 ]]; then
    echo "No known legacy Marzban data tables found in source database $source_mysql_db" >&2
    exit 4
  fi

  printf '%s\n' "${tables_to_dump[@]}" > "$OUT_DIR/source_tables_to_dump.txt"
  echo "Will import data-only for tables: ${tables_to_dump[*]}"

  echo "Dumping source legacy MySQL data (no schema, complete-insert): $source_mysql_db"
  write_mysql_columns_json "$SOURCE_REF" "$MYSQL_CONTAINER" "$source_mysql_db" "$OUT_DIR/source_mysql_columns.json" "${tables_to_dump[@]}"
  table_args="${tables_to_dump[*]}"
  run_ssh "$SOURCE_REF" "docker exec '$MYSQL_CONTAINER' sh -lc 'if [ -n \"\${MYSQL_ROOT_PASSWORD:-}\" ]; then mysqldump --default-character-set=utf8mb4 --single-transaction --skip-triggers --no-create-info --complete-insert --skip-extended-insert -uroot -p\"\$MYSQL_ROOT_PASSWORD\" \"$source_mysql_db\" $table_args; else mysqldump --default-character-set=utf8mb4 --single-transaction --skip-triggers --no-create-info --complete-insert --skip-extended-insert \"$source_mysql_db\" $table_args; fi'" > "$dump_sql"

  if [[ ! -s "$dump_sql" ]]; then
    echo "Source data dump file is empty: $dump_sql" >&2
    exit 5
  fi

  echo "Legacy dump saved: $dump_sql ($(wc -c < "$dump_sql") bytes)"

  if [[ "$MYSQL_SWAP_AT_RESTORE" == "true" ]]; then
    echo "=== Phase 2: swap MySQL on source (stop legacy, start partner on :3306) ==="
    swap_legacy_to_partner_mysql
  else
    echo "=== Phase 2: skip swap (MYSQL_SWAP_AT_RESTORE=false) ==="
    if [[ "$(docker_container_running "$PANEL_REF" "$PANEL_MYSQL_CONTAINER")" != "true" ]]; then
      echo "Partner MySQL container is not running: $PANEL_MYSQL_CONTAINER" >&2
      exit 6
    fi
    wait_partner_mysql_ready 12
  fi
fi

remote_panel_mysql_env > "$panel_mysql_env_file"
panel_mysql_db="$(awk -F= '$1=="MYSQL_DATABASE"{print $2}' "$panel_mysql_env_file")"

if [[ -z "$panel_mysql_db" ]]; then
  echo "Failed to detect partner mysql database name" >&2
  exit 7
fi

if [[ "$(panel_mysql_table_exists "$panel_mysql_db" "bots")" != "1" \
   || "$(panel_mysql_table_exists "$panel_mysql_db" "admins")" != "1" ]]; then
  echo "Partner fork schema missing (empty MySQL after swap). Restarting so Alembic can create tables."
  restart_partner_stack
  wait_partner_mysql_ready 60
  wait_partner_fork_schema "$panel_mysql_db" 60
fi
ensure_partner_panel_admin "$panel_mysql_db"

echo "=== Phase 3: import legacy data into partner fork schema ==="
if [[ "$SKIP_NODE_USAGE_TABLES" == "true" ]]; then
  echo "SKIP_NODE_USAGE_TABLES=true: node_usages / node_user_usages will not be imported (node stats empty)"
fi
tables_to_import=()
for table in "${tables_to_dump[@]}"; do
  if is_usage_skip_table "$table"; then
    echo "Skip usage table $table (SKIP_NODE_USAGE_TABLES=true)"
    continue
  fi
  if [[ "$(panel_mysql_table_exists "$panel_mysql_db" "$table")" == "1" ]]; then
    tables_to_import+=("$table")
  else
    echo "Skip table $table: not present on partner fork schema"
  fi
done
if [[ ${#tables_to_import[@]} -eq 0 ]]; then
  echo "No overlapping tables between legacy dump and partner schema" >&2
  exit 9
fi

write_mysql_columns_json "$PANEL_REF" "$PANEL_MYSQL_CONTAINER" "$panel_mysql_db" "$OUT_DIR/dest_mysql_columns.json" "${tables_to_import[@]}"
rewritten_sql="$OUT_DIR/partner_import_filtered.sql"
rewrite_skip_args=()
if [[ "$SKIP_NODE_USAGE_TABLES" == "true" ]]; then
  rewrite_skip_args+=(--skip-tables "node_usages,node_user_usages")
fi
echo "Rewriting dump to dest column intersection"
python3 "$SCRIPT_DIR/rewrite_mysqldump.py" \
  "$dump_sql" \
  "$OUT_DIR/dest_mysql_columns.json" \
  "$rewritten_sql" \
  --source-columns-json "$OUT_DIR/source_mysql_columns.json" \
  "${rewrite_skip_args[@]}" \
  | tee "$OUT_DIR/rewrite_stats.json"

{
  echo "SET FOREIGN_KEY_CHECKS=0;"
  for table in "${tables_to_import[@]}"; do
    echo "TRUNCATE TABLE \`${table}\`;"
  done
  if [[ "$SKIP_NODE_USAGE_TABLES" == "true" ]]; then
    for table in "${USAGE_SKIP_TABLES[@]}"; do
      if [[ "$(panel_mysql_table_exists "$panel_mysql_db" "$table")" == "1" ]]; then
        echo "TRUNCATE TABLE \`${table}\`;"
      fi
    done
  fi
  echo "SET FOREIGN_KEY_CHECKS=1;"
} > "$truncate_sql"

echo "Clearing partner panel data tables before import"
run_ssh "$PANEL_REF" "docker exec -i '$PANEL_MYSQL_CONTAINER' sh -lc 'if [ -n \"\${MYSQL_ROOT_PASSWORD:-}\" ]; then mysql --default-character-set=utf8mb4 -uroot -p\"\$MYSQL_ROOT_PASSWORD\" \"$panel_mysql_db\"; else mysql --default-character-set=utf8mb4 \"$panel_mysql_db\"; fi'" < "$truncate_sql"

echo "Importing rewritten legacy data into partner panel MySQL (fork schema preserved)"
run_ssh "$PANEL_REF" "docker exec -i '$PANEL_MYSQL_CONTAINER' sh -lc 'if [ -n \"\${MYSQL_ROOT_PASSWORD:-}\" ]; then mysql --default-character-set=utf8mb4 -uroot -p\"\$MYSQL_ROOT_PASSWORD\" \"$panel_mysql_db\"; else mysql --default-character-set=utf8mb4 \"$panel_mysql_db\"; fi'" < "$rewritten_sql"

echo "=== Phase 4: bind users to migrated bot ==="
source_bot_sql=""
source_bot_update=""
if [[ "$(mysql_column_exists "$PANEL_REF" "$PANEL_MYSQL_CONTAINER" "$panel_mysql_db" "bots" "source_bot_id")" == "1" ]]; then
  source_bot_sql=", source_bot_id"
  source_bot_val=", ${TARGET_BOT_ID}"
  source_bot_update=", source_bot_id=VALUES(source_bot_id)"
else
  source_bot_val=""
fi
cat > "$normalize_sql" <<SQL
START TRANSACTION;

INSERT INTO bots (username, title, created_at, updated_at${source_bot_sql})
VALUES ('${TARGET_BOT_USERNAME}', '${TARGET_BOT_USERNAME}', NOW(), NOW()${source_bot_val})
ON DUPLICATE KEY UPDATE title=VALUES(title), updated_at=NOW()${source_bot_update};

SET @bot_id := (SELECT id FROM bots WHERE username='${TARGET_BOT_USERNAME}' LIMIT 1);

UPDATE users
SET bot_id=@bot_id
WHERE bot_id IS NULL;

INSERT INTO bot_settings (bot_id, data, created_at, updated_at)
SELECT @bot_id, JSON_OBJECT(), NOW(), NOW()
WHERE NOT EXISTS (SELECT 1 FROM bot_settings WHERE bot_id=@bot_id);

COMMIT;

SELECT 'partner_bot_id' AS metric, @bot_id AS value;
SELECT 'users_with_partner_bot_id' AS metric, COUNT(*) AS value FROM users WHERE bot_id=@bot_id;
SELECT 'users_without_bot_id' AS metric, COUNT(*) AS value FROM users WHERE bot_id IS NULL;
SELECT 'host_associations_for_partner_bot' AS metric, COUNT(*) AS value FROM host_bot_association WHERE bot_id=@bot_id;
SQL

echo "Applying partner post-restore normalization"
run_ssh "$PANEL_REF" "docker exec -i '$PANEL_MYSQL_CONTAINER' sh -lc 'if [ -n \"\${MYSQL_ROOT_PASSWORD:-}\" ]; then mysql --default-character-set=utf8mb4 -uroot -p\"\$MYSQL_ROOT_PASSWORD\" \"$panel_mysql_db\"; else mysql --default-character-set=utf8mb4 \"$panel_mysql_db\"; fi'" < "$normalize_sql" | tee "$OUT_DIR/partner_post_restore_result.txt"

echo "Restarting partner Marzban after import"
run_panel_ssh "cd '${PANEL_PATH}' && marzban restart -n"

echo "MySQL swap + data import + bot binding complete: $OUT_DIR"
