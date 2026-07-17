#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

: "${TARGET_BOT_API_TOKEN:?Set TARGET_BOT_API_TOKEN in migration.env or environment}"
: "${TARGET_BOT_PUBLIC_NAME:=vpnZab_copy_bot}"
: "${TARGET_BOT_ADMIN_ID:=1}"
: "${TARGET_BOT_DOMAIN:=}"

TARGET_REF="${TARGET_USER}@${TARGET_HOST}"
target_pg_env_file="$(mktemp)"
remote_pg_env "$TARGET_REF" "$PG_CONTAINER" > "$target_pg_env_file"
pg_user="$(awk -F= '$1=="PGUSER"{print $2}' "$target_pg_env_file")"
pg_db="$(awk -F= '$1=="PGDATABASE"{print $2}' "$target_pg_env_file")"
rm -f "$target_pg_env_file"

echo "Creating/updating target bot row id=$TARGET_BOT_ID username=$TARGET_BOT_USERNAME"
run_ssh "$TARGET_REF" "docker exec -i '$PG_CONTAINER' psql -v ON_ERROR_STOP=1 -U '$pg_user' -d '$pg_db'" >/dev/null <<SQL
BEGIN;
INSERT INTO bots (id, username, public_name, api_token, webhook, domain, admin_id)
VALUES (${TARGET_BOT_ID}, '${TARGET_BOT_USERNAME}', '${TARGET_BOT_PUBLIC_NAME}', '${TARGET_BOT_API_TOKEN}', NULL, NULLIF('${TARGET_BOT_DOMAIN}',''), ${TARGET_BOT_ADMIN_ID})
ON CONFLICT (id) DO UPDATE SET
  username = EXCLUDED.username,
  public_name = EXCLUDED.public_name,
  api_token = EXCLUDED.api_token,
  domain = EXCLUDED.domain,
  admin_id = EXCLUDED.admin_id;
INSERT INTO bot_settings (bot_id, data)
VALUES (${TARGET_BOT_ID}, '{}'::jsonb)
ON CONFLICT (bot_id) DO NOTHING;
SELECT setval(pg_get_serial_sequence('bots','id'), GREATEST((SELECT COALESCE(MAX(id),1) FROM bots), 1), true)
WHERE pg_get_serial_sequence('bots','id') IS NOT NULL;
COMMIT;
SQL
echo "Target bot row is ready."

