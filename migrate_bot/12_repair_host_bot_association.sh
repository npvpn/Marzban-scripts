#!/usr/bin/env bash
# Undo INSERT IGNORE INTO host_bot_association ... SELECT h.id, @bot_id FROM hosts h
# for TARGET_BOT_USERNAME. Empty host lists mean "all bots"; do not add the new bot.
#
# DRY_RUN=true  — only print current associations (default)
# DRY_RUN=false — DELETE rows for that bot, then restart the panel (host cache)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

DRY_RUN="${DRY_RUN:-true}"
RUN_ID="${RUN_ID:-$(timestamp)}"
OUT_DIR="$ARTIFACT_ROOT/$RUN_ID/host_assoc_repair"
mkdir -p "$OUT_DIR"

PANEL_REF="${PANEL_USER}@${PANEL_HOST}"
bot_sql="${TARGET_BOT_USERNAME//\'/\'\'}"

panel_mysql_env_file="$OUT_DIR/panel_mysql_env.txt"
remote_panel_mysql_env > "$panel_mysql_env_file"
panel_mysql_db="$(awk -F= '$1=="MYSQL_DATABASE"{print $2}' "$panel_mysql_env_file")"
require_partner_multibot_schema "$panel_mysql_db"

preview_sql="$OUT_DIR/preview.sql"
apply_sql="$OUT_DIR/apply.sql"

cat > "$preview_sql" <<SQL
SET @bot_id := (SELECT id FROM bots WHERE username='${bot_sql}' LIMIT 1);
SELECT 'target_bot' AS section, @bot_id AS bot_id, '${bot_sql}' AS username;
SELECT 'hosts_total' AS section, COUNT(*) AS value FROM hosts;
SELECT 'assoc_rows_for_bot' AS section, COUNT(*) AS value
FROM host_bot_association WHERE bot_id=@bot_id;
SELECT 'hosts_with_any_assoc' AS section, COUNT(DISTINCT host_id) AS value FROM host_bot_association;
SELECT 'hosts_only_this_bot' AS section, COUNT(*) AS value
FROM (
  SELECT host_id FROM host_bot_association
  GROUP BY host_id
  HAVING COUNT(*) = 1 AND MAX(bot_id) = @bot_id
) t;
SELECT 'hosts_shared_with_others' AS section, COUNT(*) AS value
FROM (
  SELECT host_id FROM host_bot_association
  WHERE host_id IN (SELECT host_id FROM host_bot_association WHERE bot_id=@bot_id)
  GROUP BY host_id
  HAVING COUNT(*) > 1
) t;
SELECT h.id AS host_id, h.remark, hba.bot_id, b.username AS bot_username
FROM hosts h
LEFT JOIN host_bot_association hba ON hba.host_id=h.id
LEFT JOIN bots b ON b.id=hba.bot_id
ORDER BY h.id, b.username;
SQL

cat > "$apply_sql" <<SQL
START TRANSACTION;
SET @bot_id := (SELECT id FROM bots WHERE username='${bot_sql}' LIMIT 1);
SELECT IF(@bot_id IS NULL, 1, 0) AS abort_if_bot_missing;
DELETE FROM host_bot_association WHERE bot_id=@bot_id;
COMMIT;
SELECT 'assoc_rows_for_bot_after' AS section, COUNT(*) AS value
FROM host_bot_association WHERE bot_id=@bot_id;
SELECT 'hosts_with_any_assoc_after' AS section, COUNT(DISTINCT host_id) AS value FROM host_bot_association;
SQL

echo "Current host_bot_association snapshot (${TARGET_BOT_USERNAME})"
run_ssh "$PANEL_REF" "docker exec -i '$PANEL_MYSQL_CONTAINER' sh -lc 'if [ -n \"\${MYSQL_ROOT_PASSWORD:-}\" ]; then mysql --default-character-set=utf8mb4 -uroot -p\"\$MYSQL_ROOT_PASSWORD\" \"$panel_mysql_db\"; else mysql --default-character-set=utf8mb4 \"$panel_mysql_db\"; fi'" \
  < "$preview_sql" | tee "$OUT_DIR/preview.txt"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY_RUN=true: associations not deleted. To apply:"
  echo "  DRY_RUN=false ./12_repair_host_bot_association.sh"
  exit 0
fi

echo "Deleting host_bot_association rows for ${TARGET_BOT_USERNAME}"
run_ssh "$PANEL_REF" "docker exec -i '$PANEL_MYSQL_CONTAINER' sh -lc 'if [ -n \"\${MYSQL_ROOT_PASSWORD:-}\" ]; then mysql --default-character-set=utf8mb4 -uroot -p\"\$MYSQL_ROOT_PASSWORD\" \"$panel_mysql_db\"; else mysql --default-character-set=utf8mb4 \"$panel_mysql_db\"; fi'" \
  < "$apply_sql" | tee "$OUT_DIR/apply_result.txt"

echo "Restarting panel so subscription host cache reloads"
if run_panel_ssh "command -v marzban >/dev/null 2>&1"; then
  run_panel_ssh "cd '${PANEL_PATH}' && marzban restart -n"
elif run_panel_ssh "cd '${PANEL_PATH}' && docker compose restart marzban >/dev/null 2>&1"; then
  true
else
  run_panel_ssh "docker restart nvb_marz"
fi

echo "Repair complete: $OUT_DIR"
echo "Empty host allowlists are everyone (including ${TARGET_BOT_USERNAME})."
echo "Hosts that already listed other bots stay on those bots only."
