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
  -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-60}"
)
SOURCE_SSH_OPTS=("${SSH_BASE_OPTS[@]}" -o PreferredAuthentications=publickey,password)
TARGET_SSH_OPTS=("${SSH_BASE_OPTS[@]}" -o PreferredAuthentications=publickey)
PANEL_SSH_OPTS=("${SSH_BASE_OPTS[@]}" -o PreferredAuthentications=publickey,password)

SOURCE_SSH=("${SOURCE_USER}@${SOURCE_HOST}")
TARGET_SSH=("${TARGET_USER}@${TARGET_HOST}")
PANEL_SSH=("${PANEL_USER}@${PANEL_HOST}")
PANEL_USE_SUDO="${PANEL_USE_SUDO:-false}"

host_needs_sudo() {
  local host_ref="$1"
  [[ "${PANEL_USE_SUDO}" == "true" ]] || return 1
  [[ "$host_ref" == "${PANEL_SSH[0]}" || "$host_ref" == "${TARGET_SSH[0]}" ]]
}

run_ssh() {
  local host_ref="$1"
  shift
  local -a remote=("$@")
  if host_needs_sudo "$host_ref"; then
    remote=("sudo -n bash -lc $(printf '%q' "$*")")
  fi
  if [[ "$host_ref" == "${SOURCE_SSH[0]}" ]]; then
    if [[ -n "${MIGRATION_SSH_PASSWORD:-}" ]]; then
      SSH_ASKPASS="$SCRIPT_DIR/askpass.sh" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}" \
        ssh "${SOURCE_SSH_OPTS[@]}" "$host_ref" "${remote[@]}"
    else
      ssh "${SOURCE_SSH_OPTS[@]}" "$host_ref" "${remote[@]}"
    fi
  elif [[ "$host_ref" == "${PANEL_SSH[0]}" ]]; then
    if [[ -n "${PANEL_SSH_PASSWORD:-${MIGRATION_SSH_PASSWORD:-}}" ]]; then
      MIGRATION_SSH_PASSWORD="${PANEL_SSH_PASSWORD:-$MIGRATION_SSH_PASSWORD}" \
      SSH_ASKPASS="$SCRIPT_DIR/askpass.sh" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}" \
        ssh "${PANEL_SSH_OPTS[@]}" "$host_ref" "${remote[@]}"
    else
      ssh "${PANEL_SSH_OPTS[@]}" "$host_ref" "${remote[@]}"
    fi
  else
    env -u SSH_ASKPASS -u SSH_ASKPASS_REQUIRE ssh "${TARGET_SSH_OPTS[@]}" "$host_ref" "${remote[@]}"
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

mysql_column_exists() {
  local host_ref="$1"
  local mysql_container="$2"
  local mysql_db="$3"
  local table_name="$4"
  local column_name="$5"
  local mysql_db_sql="${mysql_db//\'/\'\'}"
  local table_name_sql="${table_name//\'/\'\'}"
  local column_name_sql="${column_name//\'/\'\'}"
  printf '%s\n' \
    "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='${mysql_db_sql}' AND table_name='${table_name_sql}' AND column_name='${column_name_sql}';" \
    | mysql_query_raw "$host_ref" "$mysql_container" "$mysql_db" \
    | tr -d '\r' | awk 'NF{print; exit}'
}

write_mysql_columns_json() {
  local host_ref="$1"
  local mysql_container="$2"
  local mysql_db="$3"
  local out_json="$4"
  shift 4
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local table
  for table in "$@"; do
    mysql_column_names "$host_ref" "$mysql_container" "$mysql_db" "$table" > "$tmp_dir/$table.txt" || true
  done
  python3 - "$tmp_dir" "$out_json" <<'PY'
import json, sys
from pathlib import Path
src, out = Path(sys.argv[1]), Path(sys.argv[2])
data = {}
for path in sorted(src.glob("*.txt")):
    cols = [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    if cols:
        data[path.stem] = cols
out.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
  rm -rf "$tmp_dir"
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
  local source_bot_id="${6:-}"
  local remote_json="/tmp/migration_panel_bot_settings_${bot_username}.json"
  upload_utf8_file "$local_json" "$host_ref" "$remote_json"
  run_ssh "$host_ref" "python3 - '$remote_json' '$bot_username' '$mysql_container' '$mysql_db' '${source_bot_id}'" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

remote_json, bot_username, mysql_container, mysql_db, source_bot_id = sys.argv[1:6]
data = json.loads(Path(remote_json).read_text(encoding="utf-8"))
payload = json.dumps(data, ensure_ascii=False)
payload_sql = payload.replace("\\", "\\\\").replace("'", "''")
bot_sql = bot_username.replace("'", "''")
source_sql = ""
source_update = ""
if source_bot_id.strip().isdigit():
    source_sql = f", source_bot_id"
    source_val = f", {source_bot_id.strip()}"
    source_update = ", source_bot_id=VALUES(source_bot_id)"
else:
    source_val = ""
sql = f"""INSERT INTO bots (username, title, created_at, updated_at{source_sql})
VALUES ('{bot_sql}', '{bot_sql}', NOW(), NOW(){source_val})
ON DUPLICATE KEY UPDATE title=VALUES(title), updated_at=NOW(){source_update};
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

apply_panel_global_settings_json() {
  local local_json="$1"
  local host_ref="$2"
  local mysql_db="$3"
  local mysql_container="${4:-$MYSQL_CONTAINER}"
  if [[ ! -s "$local_json" ]]; then
    return 0
  fi
  if python3 - "$local_json" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
sys.exit(0 if data else 1)
PY
  then
    :
  else
    echo "panel global_settings patch is empty, skip"
    return 0
  fi
  local remote_json="/tmp/migration_panel_global_settings.json"
  upload_utf8_file "$local_json" "$host_ref" "$remote_json"
  run_ssh "$host_ref" "python3 - '$remote_json' '$mysql_container' '$mysql_db'" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

remote_json, mysql_container, mysql_db = sys.argv[1:4]
data = json.loads(Path(remote_json).read_text(encoding="utf-8"))
if not data:
    Path(remote_json).unlink(missing_ok=True)
    raise SystemExit(0)
payload = json.dumps(data, ensure_ascii=False)
payload_sql = payload.replace("\\", "\\\\").replace("'", "''")
sql = f"""INSERT INTO global_settings (`key`, data, created_at, updated_at)
VALUES ('panel', CAST('{payload_sql}' AS JSON), NOW(), NOW())
ON DUPLICATE KEY UPDATE
  data = JSON_MERGE_PATCH(IFNULL(data, JSON_OBJECT()), VALUES(data)),
  updated_at = NOW();
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
UPDATE bot_settings SET data = '{patch_sql}'::jsonb, updated_at = CURRENT_TIMESTAMP WHERE bot_id = {bot_id};
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

remote_source_files_dir() {
  run_ssh "${SOURCE_SSH[0]}" "if [ -d '${SOURCE_PATH}/src/files' ]; then printf '%s' '${SOURCE_PATH}/src/files'; elif [ -d '${SOURCE_PATH}/files' ]; then printf '%s' '${SOURCE_PATH}/files'; fi"
}

remote_target_files_dir() {
  run_ssh "${TARGET_SSH[0]}" "if [ -d '${TARGET_PATH}/src/files' ]; then printf '%s' '${TARGET_PATH}/src/files'; elif [ -d '${TARGET_PATH}/files' ]; then printf '%s' '${TARGET_PATH}/files'; else printf '%s' '${TARGET_PATH}/src/files'; fi"
}

list_source_files() {
  local list_out="$1"
  local dir
  dir="$(remote_source_files_dir || true)"
  {
    echo "SOURCE_FILES_DIR=${dir}"
    if [[ -n "$dir" ]]; then
      run_ssh "${SOURCE_SSH[0]}" "find '$dir' -maxdepth 1 -type f ! -name '.*' -printf '%f\\n' | sort"
    fi
  } > "$list_out"
  local count
  count="$(awk 'NR>1 && NF{c++} END{print c+0}' "$list_out")"
  echo "count=$count" >> "$list_out"
}

fetch_source_files_tgz() {
  local out_tgz="$1"
  local list_out="${2:-}"
  local dir
  dir="$(remote_source_files_dir || true)"
  if [[ -n "$list_out" ]]; then
    {
      echo "SOURCE_FILES_DIR=${dir}"
      if [[ -n "$dir" ]]; then
        run_ssh "${SOURCE_SSH[0]}" "find '$dir' -maxdepth 1 -type f ! -name '.*' -printf '%f\\n' | sort"
      fi
    } > "$list_out"
    local count
    count="$(awk 'NR>1 && NF{c++} END{print c+0}' "$list_out")"
    echo "count=$count" >> "$list_out"
  fi
  if [[ -z "$dir" ]]; then
    echo "Source src/files not found under $SOURCE_PATH (no message images to copy)" >&2
    : > "$out_tgz"
    return 0
  fi
  run_ssh "${SOURCE_SSH[0]}" "tar -czf - -C '$dir' ." > "$out_tgz"
}

copy_prefixed_bot_files_to_target() {
  local src_tgz="$1"
  local manifest="${2:-}"
  if [[ ! -s "$src_tgz" ]]; then
    echo "No source message images archive to copy"
    return 0
  fi
  local dest_tgz
  dest_tgz="$(mktemp --suffix=.tgz)"
  local tmp_manifest
  tmp_manifest="$(mktemp)"
  python3 "$SCRIPT_DIR/copy_bot_files.py" \
    --src-tgz "$src_tgz" \
    --bot-id "$TARGET_BOT_ID" \
    --dest-tgz "$dest_tgz" \
    --manifest "$tmp_manifest"
  if [[ -n "$manifest" ]]; then
    cp "$tmp_manifest" "$manifest"
  fi
  if [[ ! -s "$dest_tgz" ]]; then
    echo "Source files archive had no regular files to copy"
    rm -f "$dest_tgz" "$tmp_manifest"
    return 0
  fi
  local dest_dir
  dest_dir="$(remote_target_files_dir)"
  echo "Copying prefixed message images to ${TARGET_SSH[0]}:${dest_dir} as ${TARGET_BOT_ID}__*"
  cat "$dest_tgz" | run_ssh "${TARGET_SSH[0]}" "mkdir -p '$dest_dir' && tar -xzf - -C '$dest_dir' && owner=\$(stat -c '%u:%g' '$dest_dir') && chown \"\$owner\" '$dest_dir'/${TARGET_BOT_ID}__* 2>/dev/null || true"
  local count
  count="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("count",0))' "$tmp_manifest")"
  echo "Copied $count file(s) to $dest_dir"
  rm -f "$dest_tgz" "$tmp_manifest"
}

