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

ENV_TGZ="$EXPORT_DIR/source_env_files.tgz"
if [[ ! -s "$ENV_TGZ" ]]; then
  echo "Missing source env archive: $ENV_TGZ" >&2
  exit 2
fi

RUN_ID="${RUN_ID:-$(timestamp)}"
OUT_DIR="$ARTIFACT_ROOT/$RUN_ID/settings"
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

TMP_ENV_DIR="$(mktemp -d)"
tar -xzf "$ENV_TGZ" -C "$TMP_ENV_DIR" 2>/dev/null || true

SETTINGS_JSON="$OUT_DIR/bot_settings_patch.json"
PANEL_JSON="$OUT_DIR/panel_bot_settings.json"
PANEL_GLOBAL_JSON="$OUT_DIR/panel_global_settings.json"
PAYMENT_SQL="$OUT_DIR/payment_settings.sql"

python3 "$SCRIPT_DIR/settings_from_env.py" \
  --env-dir "$TMP_ENV_DIR" \
  --out-dir "$OUT_DIR" \
  --target-bot-domain "${TARGET_BOT_DOMAIN:-}" \
  --target-bot-username "${TARGET_BOT_USERNAME}" \
  --target-bot-public-name "${TARGET_BOT_PUBLIC_NAME:-}" \
  --target-bot-id "${TARGET_BOT_ID}"
chmod 600 "$SETTINGS_JSON" "$PANEL_JSON" "$PANEL_GLOBAL_JSON" "$PAYMENT_SQL" 2>/dev/null || true

TARGET_REF="${TARGET_USER}@${TARGET_HOST}"
SOURCE_REF="${SOURCE_USER}@${SOURCE_HOST}"
PANEL_REF="${PANEL_USER}@${PANEL_HOST}"

target_pg_env_file="$OUT_DIR/target_pg_env.txt"
remote_pg_env "$TARGET_REF" "$PG_CONTAINER" > "$target_pg_env_file"
pg_user="$(awk -F= '$1=="PGUSER"{print $2}' "$target_pg_env_file")"
pg_db="$(awk -F= '$1=="PGDATABASE"{print $2}' "$target_pg_env_file")"

echo "Applying bot feature settings and payment settings to target PG"
apply_pg_bot_settings_patch_json "$SETTINGS_JSON" "$TARGET_REF" "$TARGET_BOT_ID" "$pg_user" "$pg_db"
run_ssh "$TARGET_REF" "docker exec -i '$PG_CONTAINER' psql -v ON_ERROR_STOP=1 -U '$pg_user' -d '$pg_db'" >/dev/null <<SQL
$(sed 's/\\/\\\\/g' "$PAYMENT_SQL")
SQL

echo "Applying panel bot and panel bot_settings to partner panel MySQL"
panel_mysql_env_file="$OUT_DIR/panel_mysql_env.txt"
remote_panel_mysql_env > "$panel_mysql_env_file"
panel_mysql_db="$(awk -F= '$1=="MYSQL_DATABASE"{print $2}' "$panel_mysql_env_file")"
source_bot_id_arg=""
if [[ "$(mysql_column_exists "$PANEL_REF" "$PANEL_MYSQL_CONTAINER" "$panel_mysql_db" "bots" "source_bot_id")" == "1" ]]; then
  source_bot_id_arg="$TARGET_BOT_ID"
fi
apply_panel_bot_settings_json "$PANEL_JSON" "$PANEL_REF" "$TARGET_BOT_USERNAME" "$panel_mysql_db" "$PANEL_MYSQL_CONTAINER" "$source_bot_id_arg"
if [[ "$(panel_mysql_table_exists "$panel_mysql_db" "global_settings")" == "1" ]]; then
  echo "Applying panel global_settings (routing) to partner panel MySQL"
  apply_panel_global_settings_json "$PANEL_GLOBAL_JSON" "$PANEL_REF" "$panel_mysql_db" "$PANEL_MYSQL_CONTAINER"
else
  echo "Warning: global_settings table missing on partner panel, routing keys not applied" >&2
fi

echo "Reading legacy JWT secret and adding it to partner SUBSCRIPTION_LEGACY_SECRET_KEYS"
panel_mysql_env_file="$OUT_DIR/panel_mysql_env.txt"
remote_panel_mysql_env > "$panel_mysql_env_file"
panel_mysql_db="$(awk -F= '$1=="MYSQL_DATABASE"{print $2}' "$panel_mysql_env_file")"

read_jwt_secret_from_mysql() {
  local host_ref="$1"
  local mysql_container="$2"
  local mysql_db="$3"
  run_ssh "$host_ref" "docker exec '$mysql_container' sh -lc 'if [ -n \"\${MYSQL_ROOT_PASSWORD:-}\" ]; then mysql -N -B -uroot -p\"\$MYSQL_ROOT_PASSWORD\" \"$mysql_db\" -e \"SELECT secret_key FROM jwt LIMIT 1\"; else mysql -N -B \"$mysql_db\" -e \"SELECT secret_key FROM jwt LIMIT 1\"; fi'" 2>/dev/null \
    | tr -d '\r' | awk 'NF{print; exit}'
}

legacy_secret=""
if [[ -n "${PANEL_MYSQL_CONTAINER:-}" ]]; then
  echo "Trying partner panel MySQL (${PANEL_MYSQL_CONTAINER})"
  legacy_secret="$(read_jwt_secret_from_mysql "$PANEL_REF" "$PANEL_MYSQL_CONTAINER" "$panel_mysql_db" || true)"
fi

if [[ -z "$legacy_secret" ]]; then
  source_mysql_env_file="$OUT_DIR/source_mysql_env.txt"
  remote_mysql_env "$SOURCE_REF" "$MYSQL_CONTAINER" > "$source_mysql_env_file" 2>/dev/null || true
  source_mysql_db="$(awk -F= '$1=="MYSQL_DATABASE"{print $2}' "$source_mysql_env_file")"
  if [[ -n "$source_mysql_db" ]]; then
    echo "Trying legacy MySQL (${MYSQL_CONTAINER})"
    legacy_secret="$(read_jwt_secret_from_mysql "$SOURCE_REF" "$MYSQL_CONTAINER" "$source_mysql_db" || true)"
  fi
fi

if [[ -z "$legacy_secret" ]]; then
  dump_glob="$ARTIFACT_ROOT"/*/mysql_restore/source_legacy_data.sql
  for dump_file in $dump_glob; do
    [[ -f "$dump_file" ]] || continue
    legacy_secret="$(python3 - "$dump_file" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
match = re.search(r"INSERT INTO `jwt`(?:\s*\([^)]+\))? VALUES \((?:1,\s*)?'([0-9a-f]+)'", text)
print(match.group(1) if match else "", end="")
PY
)"
    [[ -n "$legacy_secret" ]] && echo "Recovered JWT secret from saved mysql dump: $dump_file" && break
  done
fi

if [[ -n "$legacy_secret" ]]; then
  echo "Writing SUBSCRIPTION_LEGACY_SECRET_KEYS to ${PANEL_ENV_FILE}"
  run_panel_ssh "python3 - '$PANEL_ENV_FILE' '$legacy_secret' <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
secret = sys.argv[2].strip()
lines = path.read_text(errors='ignore').splitlines() if path.exists() else []
key = 'SUBSCRIPTION_LEGACY_SECRET_KEYS'
found = False
out = []
for line in lines:
    if line.startswith(key + '='):
        found = True
        current = line.split('=', 1)[1].strip().strip('\"').strip(\"'\")
        values = [x.strip() for x in current.split(',') if x.strip()]
        if secret not in values:
            values.append(secret)
        out.append(key + '=' + ','.join(values))
    else:
        out.append(line)
if not found:
    out.append(key + '=' + secret)
path.write_text('\\n'.join(out) + '\\n')
PY"
  echo "Restarting partner Marzban to apply SUBSCRIPTION_LEGACY_SECRET_KEYS"
  run_panel_ssh "cd '${PANEL_PATH}' && marzban restart -n"
else
  echo "Warning: legacy JWT secret was not found; panel env was not changed" >&2
  echo "Add it manually to ${PANEL_ENV_FILE} and run: cd ${PANEL_PATH} && marzban restart -n" >&2
fi

rm -rf "$TMP_ENV_DIR"
echo "Settings apply complete. Sensitive generated files are in $OUT_DIR"

