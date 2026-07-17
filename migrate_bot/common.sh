#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/migration.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE. Copy migration.env.example to migration.env and fill secrets outside git." >&2
  exit 2
fi

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${SOURCE_HOST:?}"
: "${SOURCE_USER:?}"
: "${SOURCE_PATH:?}"
: "${TARGET_HOST:?}"
: "${TARGET_USER:?}"
: "${TARGET_PATH:?}"
: "${PG_CONTAINER:?}"
: "${MYSQL_CONTAINER:?}"
: "${PANEL_HOST:=$SOURCE_HOST}"
: "${PANEL_USER:=$SOURCE_USER}"
: "${PANEL_PATH:=$SOURCE_PATH}"
: "${PANEL_MYSQL_CONTAINER:=$MYSQL_CONTAINER}"
: "${PANEL_ENV_FILE:=$PANEL_PATH/.env}"
: "${SOURCE_BOT_USERNAME:?}"
: "${TARGET_BOT_USERNAME:?}"
: "${TARGET_BOT_ID:?}"
: "${TARGET_SERVER_ID:?}"
: "${ARTIFACT_ROOT:?}"

SSH_BASE_OPTS=(
  -i "${SSH_KEY:-/home/alex/.ssh/id_ed25519}"
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=15
)
SOURCE_SSH_OPTS=("${SSH_BASE_OPTS[@]}" -o PreferredAuthentications=publickey,password)
TARGET_SSH_OPTS=("${SSH_BASE_OPTS[@]}" -o PreferredAuthentications=publickey)
PANEL_SSH_OPTS=("${SSH_BASE_OPTS[@]}" -o PreferredAuthentications=publickey,password)

SOURCE_SSH=("${SOURCE_USER}@${SOURCE_HOST}")
TARGET_SSH=("${TARGET_USER}@${TARGET_HOST}")
PANEL_SSH=("${PANEL_USER}@${PANEL_HOST}")

run_ssh() {
  local host_ref="$1"
  shift
  if [[ "$host_ref" == "${SOURCE_SSH[0]}" ]]; then
    if [[ -n "${MIGRATION_SSH_PASSWORD:-}" ]]; then
      SSH_ASKPASS="$SCRIPT_DIR/askpass.sh" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}" \
        ssh "${SOURCE_SSH_OPTS[@]}" "$host_ref" "$@"
    else
      ssh "${SOURCE_SSH_OPTS[@]}" "$host_ref" "$@"
    fi
  elif [[ "$host_ref" == "${PANEL_SSH[0]}" ]]; then
    if [[ -n "${PANEL_SSH_PASSWORD:-${MIGRATION_SSH_PASSWORD:-}}" ]]; then
      MIGRATION_SSH_PASSWORD="${PANEL_SSH_PASSWORD:-$MIGRATION_SSH_PASSWORD}" \
      SSH_ASKPASS="$SCRIPT_DIR/askpass.sh" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}" \
        ssh "${PANEL_SSH_OPTS[@]}" "$host_ref" "$@"
    else
      ssh "${PANEL_SSH_OPTS[@]}" "$host_ref" "$@"
    fi
  else
    env -u SSH_ASKPASS -u SSH_ASKPASS_REQUIRE ssh "${TARGET_SSH_OPTS[@]}" "$host_ref" "$@"
  fi
}

run_panel_ssh() {
  run_ssh "${PANEL_SSH[0]}" "$@"
}

timestamp() {
  date -u +%Y%m%dT%H%M%SZ
}

ensure_artifacts() {
  mkdir -p "$ARTIFACT_ROOT"
}

remote_pg_env() {
  local host_ref="$1"
  local pg_container="$2"
  run_ssh "$host_ref" "docker exec '$pg_container' sh -lc 'printf \"PGUSER=%s\\nPGDATABASE=%s\\n\" \"\${POSTGRES_USER:-postgres}\" \"\${POSTGRES_DB:-vpn_bot}\"'"
}

remote_mysql_env() {
  local host_ref="$1"
  local mysql_container="$2"
  run_ssh "$host_ref" "docker exec '$mysql_container' sh -lc 'printf \"MYSQL_DATABASE=%s\\nMYSQL_USER=%s\\n\" \"\${MYSQL_DATABASE:-marzban}\" \"\${MYSQL_USER:-root}\"'"
}

remote_panel_mysql_env() {
  remote_mysql_env "${PANEL_SSH[0]}" "${PANEL_MYSQL_CONTAINER}"
}

run_mysql() {
  local host_ref="$1"
  local db="$2"
  local mysql_container="${3:-$MYSQL_CONTAINER}"
  run_ssh "$host_ref" "docker exec -i '$mysql_container' sh -lc 'if [ -n \"\${MYSQL_ROOT_PASSWORD:-}\" ]; then mysql --default-character-set=utf8mb4 -uroot -p\"\$MYSQL_ROOT_PASSWORD\" \"$db\"; else mysql --default-character-set=utf8mb4 \"$db\"; fi'"
}

run_panel_mysql() {
  local db="$1"
  run_mysql "${PANEL_SSH[0]}" "$db" "$PANEL_MYSQL_CONTAINER"
}

mysql_table_exists() {
  local host_ref="$1"
  local mysql_container="$2"
  local mysql_db="$3"
  local table_name="$4"
  local mysql_db_sql="${mysql_db//\'/\'\'}"
  local table_name_sql="${table_name//\'/\'\'}"
  printf '%s\n' \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${mysql_db_sql}' AND table_name='${table_name_sql}';" \
    | run_ssh "$host_ref" "docker exec -i '$mysql_container' sh -lc 'if [ -n \"\${MYSQL_ROOT_PASSWORD:-}\" ]; then mysql -N -B -uroot -p\"\$MYSQL_ROOT_PASSWORD\"; else mysql -N -B; fi'" \
    | tr -d '\r' | awk 'NF{print; exit}'
}

panel_mysql_table_exists() {
  local mysql_db="$1"
  local table_name="$2"
  mysql_table_exists "${PANEL_SSH[0]}" "$PANEL_MYSQL_CONTAINER" "$mysql_db" "$table_name"
}

require_partner_multibot_schema() {
  local mysql_db="$1"
  if [[ "$(panel_mysql_table_exists "$mysql_db" "bots")" != "1" ]]; then
    echo "Partner panel MySQL schema is legacy (table bots missing)." >&2
    echo "Run ./08_install_partner_panel_source.sh, set PANEL_PATH/PANEL_MYSQL_CONTAINER to the partner install, then ./09_mysql_full_dump_restore_source_partner.sh." >&2
    exit 3
  fi
}

upload_utf8_file() {
  local local_path="$1"
  local host_ref="$2"
  local remote_path="$3"
  cat "$local_path" | run_ssh "$host_ref" "cat > '$remote_path'"
}

apply_panel_bot_settings_json() {
  local local_json="$1"
  local host_ref="$2"
  local bot_username="$3"
  local mysql_db="$4"
  local mysql_container="${5:-$MYSQL_CONTAINER}"
  local remote_json="/tmp/migration_panel_bot_settings_${bot_username}.json"
  upload_utf8_file "$local_json" "$host_ref" "$remote_json"
  run_ssh "$host_ref" "python3 - '$remote_json' '$bot_username' '$mysql_container' '$mysql_db'" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

remote_json, bot_username, mysql_container, mysql_db = sys.argv[1:5]
data = json.loads(Path(remote_json).read_text(encoding="utf-8"))
payload = json.dumps(data, ensure_ascii=False)
payload_sql = payload.replace("\\", "\\\\").replace("'", "''")
bot_sql = bot_username.replace("'", "''")
sql = f"""INSERT INTO bots (username, title, created_at, updated_at)
VALUES ('{bot_sql}', '{bot_sql}', NOW(), NOW())
ON DUPLICATE KEY UPDATE title=VALUES(title), updated_at=NOW();
INSERT INTO bot_settings (bot_id, data, created_at, updated_at)
SELECT b.id, CAST('{payload_sql}' AS JSON), NOW(), NOW()
FROM bots b WHERE b.username='{bot_sql}'
ON DUPLICATE KEY UPDATE data=VALUES(data), updated_at=NOW();
"""
cmd = (
    f"docker exec -i {mysql_container} sh -lc "
    f"\"if [ -n \\\"\\${{MYSQL_ROOT_PASSWORD:-}}\\\" ]; then "
    f"mysql --default-character-set=utf8mb4 -uroot -p\\\"\\$MYSQL_ROOT_PASSWORD\\\" {mysql_db}; "
    f"else mysql --default-character-set=utf8mb4 {mysql_db}; fi\""
)
subprocess.run(cmd, shell=True, check=True, input=sql.encode("utf-8"))
Path(remote_json).unlink(missing_ok=True)
PY
}

apply_pg_bot_settings_patch_json() {
  local local_json="$1"
  local host_ref="$2"
  local bot_id="$3"
  local pg_user="$4"
  local pg_db="$5"
  local remote_json="/tmp/migration_pg_bot_settings_${bot_id}.json"
  upload_utf8_file "$local_json" "$host_ref" "$remote_json"
  run_ssh "$host_ref" "python3 - '$remote_json' '$bot_id' '$PG_CONTAINER' '$pg_user' '$pg_db'" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

remote_json, bot_id, pg_container, pg_user, pg_db = sys.argv[1:6]
patch = json.loads(Path(remote_json).read_text(encoding="utf-8"))
patch_json = json.dumps(patch, ensure_ascii=False)
patch_sql = patch_json.replace("'", "''")
sql = f"""BEGIN;
INSERT INTO bot_settings (bot_id, data) VALUES ({bot_id}, '{{}}'::jsonb) ON CONFLICT (bot_id) DO NOTHING;
UPDATE bot_settings SET data = data || '{patch_sql}'::jsonb, updated_at = CURRENT_TIMESTAMP WHERE bot_id = {bot_id};
COMMIT;
"""
cmd = [
    "docker", "exec", "-i", pg_container,
    "psql", "-v", "ON_ERROR_STOP=1", "-U", pg_user, "-d", pg_db,
]
subprocess.run(cmd, check=True, input=sql.encode("utf-8"))
Path(remote_json).unlink(missing_ok=True)
PY
}

