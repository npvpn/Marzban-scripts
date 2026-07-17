#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

ensure_artifacts
RUN_ID="${RUN_ID:-$(timestamp)}"
OUT_DIR="$ARTIFACT_ROOT/$RUN_ID/audit"
mkdir -p "$OUT_DIR"

SOURCE_REF="${SOURCE_USER}@${SOURCE_HOST}"
TARGET_REF="${TARGET_USER}@${TARGET_HOST}"
PANEL_REF="${PANEL_USER}@${PANEL_HOST}"

echo "Audit run: $RUN_ID"
echo "Output: $OUT_DIR"

echo "== SSH/container inventory =="
for side in source target; do
  if [[ "$side" == "source" ]]; then
    ref="$SOURCE_REF"; path="$SOURCE_PATH"
  else
    ref="$TARGET_REF"; path="$TARGET_PATH"
  fi
  run_ssh "$ref" "cd '$path' && printf 'PWD=%s\n' \"\$PWD\" && docker ps --format '{{.Names}} {{.Image}} {{.Status}}' && ls -la .env .env.marzban 2>/dev/null || true" \
    > "$OUT_DIR/${side}_inventory.txt"
done

echo "== Resolve database env =="
remote_pg_env "$SOURCE_REF" "$PG_CONTAINER" > "$OUT_DIR/source_pg_env.txt"
remote_pg_env "$TARGET_REF" "$PG_CONTAINER" > "$OUT_DIR/target_pg_env.txt"
remote_mysql_env "$SOURCE_REF" "$MYSQL_CONTAINER" > "$OUT_DIR/source_mysql_env.txt"
remote_panel_mysql_env > "$OUT_DIR/panel_mysql_env.txt"

source_pg_user="$(awk -F= '$1=="PGUSER"{print $2}' "$OUT_DIR/source_pg_env.txt")"
source_pg_db="$(awk -F= '$1=="PGDATABASE"{print $2}' "$OUT_DIR/source_pg_env.txt")"
target_pg_user="$(awk -F= '$1=="PGUSER"{print $2}' "$OUT_DIR/target_pg_env.txt")"
target_pg_db="$(awk -F= '$1=="PGDATABASE"{print $2}' "$OUT_DIR/target_pg_env.txt")"

echo "== Source PG audit =="
run_ssh "$SOURCE_REF" "docker exec -i '$PG_CONTAINER' psql -v ON_ERROR_STOP=1 -U '$source_pg_user' -d '$source_pg_db'" > "$OUT_DIR/source_pg_audit.txt" <<'SQL'
\pset pager off
\pset tuples_only off
SELECT 'alembic_version' AS section, version_num FROM alembic_version;
SELECT 'counts' AS section, 'users' AS table_name, count(*) FROM users
UNION ALL SELECT 'counts','subscriptions',count(*) FROM subscriptions
UNION ALL SELECT 'counts','payments',count(*) FROM payments
UNION ALL SELECT 'counts','subscriptions_type',count(*) FROM subscriptions_type
UNION ALL SELECT 'counts','subscription_prices',count(*) FROM subscription_prices
UNION ALL SELECT 'counts','subscription_features',count(*) FROM subscription_features
UNION ALL SELECT 'counts','feature_translations',count(*) FROM feature_translations
UNION ALL SELECT 'counts','promo_codes',count(*) FROM promo_codes
UNION ALL SELECT 'counts','promo_usage_history',count(*) FROM promo_usage_history
UNION ALL SELECT 'counts','partner_balance',count(*) FROM partner_balance
UNION ALL SELECT 'counts','recurring_yookassa',count(*) FROM recurring_yookassa
UNION ALL SELECT 'counts','recurring_robokassa',count(*) FROM recurring_robokassa
UNION ALL SELECT 'counts','wireguard_subscriptions',count(*) FROM wireguard_subscriptions
UNION ALL SELECT 'counts','user_messages',count(*) FROM user_messages
UNION ALL SELECT 'counts','payments_messages',count(*) FROM payments_messages
UNION ALL SELECT 'counts','mass_messages',count(*) FROM mass_messages
UNION ALL SELECT 'counts','notification_templates',count(*) FROM notification_templates
UNION ALL SELECT 'counts','text_messages',count(*) FROM text_messages
UNION ALL SELECT 'counts','connections',count(*) FROM connections
ORDER BY table_name;
SELECT 'orphan_payments' AS section, count(*) FROM payments p LEFT JOIN subscriptions s ON s.payment_id = p.id WHERE s.id IS NULL;
SELECT 'future_marzban_username_duplicates' AS section, username, count(*)
FROM (
  SELECT CASE WHEN tg_user_id < 0 THEN 'w' || abs(tg_user_id)::text || '_' || id::text ELSE tg_user_id::text || '_' || id::text END AS username
  FROM subscriptions
) x
GROUP BY username HAVING count(*) > 1
ORDER BY count(*) DESC, username
LIMIT 100;
SQL

echo "== Source PG optional schema checks (stable-safe) =="
{
  for table in tariff_matrices web_users; do
    exists="$(run_ssh "$SOURCE_REF" "docker exec -i '$PG_CONTAINER' psql -v ON_ERROR_STOP=1 -t -A -U '$source_pg_user' -d '$source_pg_db' -c \"SELECT to_regclass('public.${table}') IS NOT NULL;\"" | tr -d '\r' | awk 'NF{print; exit}')"
    if [[ "$exists" == "t" ]]; then
      count="$(run_ssh "$SOURCE_REF" "docker exec -i '$PG_CONTAINER' psql -v ON_ERROR_STOP=1 -t -A -U '$source_pg_user' -d '$source_pg_db' -c \"SELECT count(*) FROM ${table};\"" | tr -d '\r' | awk 'NF{print; exit}')"
    else
      count="0"
    fi
    printf " counts | %s | %s\n" "$table" "$count"
  done

  check_column_count() {
    local table="$1"
    local column="$2"
    local label="$3"
    local where_clause="${4:-${column} IS NOT NULL}"
    local exists
    exists="$(run_ssh "$SOURCE_REF" "docker exec -i '$PG_CONTAINER' psql -v ON_ERROR_STOP=1 -t -A -U '$source_pg_user' -d '$source_pg_db' -c \"SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='${table}' AND column_name='${column}');\"" | tr -d '\r' | awk 'NF{print; exit}')"
    if [[ "$exists" == "t" ]]; then
      count="$(run_ssh "$SOURCE_REF" "docker exec -i '$PG_CONTAINER' psql -v ON_ERROR_STOP=1 -t -A -U '$source_pg_user' -d '$source_pg_db' -c \"SELECT count(*) FROM ${table} WHERE ${where_clause};\"" | tr -d '\r' | awk 'NF{print; exit}')"
    else
      count="0"
    fi
    printf " feature_flags | %s | %s\n" "$label" "$count"
  }

  check_column_count subscriptions_type matrix_id has_matrix_tariffs
  check_column_count subscriptions_type bs_extra_bytes has_bs_extra_tariffs
  check_column_count users extended_devices_enabled "has_extended_users" "extended_devices_enabled = true"
  check_column_count recurring_yookassa unlinked_at has_unlinked_recurring_yk
  check_column_count recurring_robokassa unlinked_at has_unlinked_recurring_rb
} >> "$OUT_DIR/source_pg_audit.txt"

echo "== Export source audit keysets =="
run_ssh "$SOURCE_REF" "docker exec -i '$PG_CONTAINER' psql -v ON_ERROR_STOP=1 -U '$source_pg_user' -d '$source_pg_db' -c \"COPY (SELECT tg_user_id, ref_link FROM users ORDER BY tg_user_id) TO STDOUT WITH CSV HEADER\"" > "$OUT_DIR/source_users_keyset.csv"
run_ssh "$SOURCE_REF" "docker exec -i '$PG_CONTAINER' psql -v ON_ERROR_STOP=1 -U '$source_pg_user' -d '$source_pg_db' -c \"COPY (SELECT id, tg_user_id, sub_type_id, is_active, date_end, CASE WHEN tg_user_id < 0 THEN 'w' || abs(tg_user_id)::text || '_' || id::text ELSE tg_user_id::text || '_' || id::text END AS marzban_username FROM subscriptions ORDER BY id) TO STDOUT WITH CSV HEADER\"" > "$OUT_DIR/source_subscriptions_keyset.csv"
run_ssh "$SOURCE_REF" "docker exec -i '$PG_CONTAINER' psql -v ON_ERROR_STOP=1 -U '$source_pg_user' -d '$source_pg_db' -c \"COPY (SELECT code FROM promo_codes ORDER BY code) TO STDOUT WITH CSV HEADER\"" > "$OUT_DIR/source_promo_codes_keyset.csv"
run_ssh "$SOURCE_REF" "docker exec -i '$PG_CONTAINER' psql -v ON_ERROR_STOP=1 -U '$source_pg_user' -d '$source_pg_db' -c \"COPY (SELECT sub_type FROM subscriptions_type ORDER BY sub_type) TO STDOUT WITH CSV HEADER\"" > "$OUT_DIR/source_sub_types_keyset.csv"

echo "== Target PG audit =="
run_ssh "$TARGET_REF" "docker exec -i '$PG_CONTAINER' psql -v ON_ERROR_STOP=1 -U '$target_pg_user' -d '$target_pg_db'" > "$OUT_DIR/target_pg_audit.txt" <<SQL
\pset pager off
SELECT 'alembic_version' AS section, version_num FROM alembic_version;
SELECT 'target_bot' AS section, id, username, public_name, domain FROM bots WHERE id = ${TARGET_BOT_ID} OR username = '${TARGET_BOT_USERNAME}';
SELECT 'target_bot_counts' AS section, 'users' AS table_name, count(*) FROM users WHERE bot_id = ${TARGET_BOT_ID}
UNION ALL SELECT 'target_bot_counts','subscriptions',count(*) FROM subscriptions WHERE bot_id = ${TARGET_BOT_ID}
UNION ALL SELECT 'target_bot_counts','payments',count(*) FROM payments WHERE bot_id = ${TARGET_BOT_ID}
UNION ALL SELECT 'target_bot_counts','subscriptions_type',count(*) FROM subscriptions_type WHERE bot_id = ${TARGET_BOT_ID}
UNION ALL SELECT 'target_bot_counts','promo_codes',count(*) FROM promo_codes WHERE bot_id = ${TARGET_BOT_ID}
ORDER BY table_name;
SQL

echo "== Target PG conflict checks from source keysets =="
{
  printf "CREATE TEMP TABLE st_users_keyset(tg_user_id bigint, ref_link text);\n"
  printf "\\copy st_users_keyset FROM STDIN WITH CSV HEADER\n"
  sed 's/\\/\\\\/g' "$OUT_DIR/source_users_keyset.csv"
  printf "\\.\n"
  printf "SELECT 'conflict_users_tg' AS section, count(*) FROM st_users_keyset s JOIN users u ON u.bot_id = %s AND u.tg_user_id = s.tg_user_id;\n" "$TARGET_BOT_ID"
  printf "SELECT 'conflict_ref_link_global' AS section, count(*) FROM st_users_keyset s JOIN users u ON u.ref_link = s.ref_link WHERE u.bot_id <> %s;\n" "$TARGET_BOT_ID"
  printf "CREATE TEMP TABLE st_subscriptions_keyset(id bigint, tg_user_id bigint, sub_type_id bigint, is_active boolean, date_end timestamptz, marzban_username text);\n"
  printf "\\copy st_subscriptions_keyset FROM STDIN WITH CSV HEADER\n"
  sed 's/\\/\\\\/g' "$OUT_DIR/source_subscriptions_keyset.csv"
  printf "\\.\n"
  printf "SELECT 'conflict_subscriptions_id' AS section, count(*) FROM st_subscriptions_keyset s JOIN subscriptions t ON t.bot_id = %s AND t.id = s.id;\n" "$TARGET_BOT_ID"
  printf "CREATE TEMP TABLE st_promo_codes_keyset(code text);\n"
  printf "\\copy st_promo_codes_keyset FROM STDIN WITH CSV HEADER\n"
  sed 's/\\/\\\\/g' "$OUT_DIR/source_promo_codes_keyset.csv"
  printf "\\.\n"
  printf "SELECT 'conflict_promo_codes' AS section, count(*) FROM st_promo_codes_keyset s JOIN promo_codes p ON p.bot_id = %s AND p.code = s.code;\n" "$TARGET_BOT_ID"
  printf "CREATE TEMP TABLE st_sub_types_keyset(sub_type text);\n"
  printf "\\copy st_sub_types_keyset FROM STDIN WITH CSV HEADER\n"
  sed 's/\\/\\\\/g' "$OUT_DIR/source_sub_types_keyset.csv"
  printf "\\.\n"
  printf "SELECT 'conflict_sub_types' AS section, count(*) FROM st_sub_types_keyset s JOIN subscriptions_type st ON st.bot_id = %s AND st.sub_type = s.sub_type;\n" "$TARGET_BOT_ID"
} | run_ssh "$TARGET_REF" "docker exec -i '$PG_CONTAINER' psql -v ON_ERROR_STOP=1 -U '$target_pg_user' -d '$target_pg_db'" > "$OUT_DIR/target_pg_conflicts.txt"

echo "== Source partner panel username collision check =="
panel_mysql_db="$(awk -F= '$1=="MYSQL_DATABASE"{print $2}' "$OUT_DIR/panel_mysql_env.txt")"
panel_has_bots_table="$(panel_mysql_table_exists "$panel_mysql_db" "bots")"
if [[ "${panel_has_bots_table:-0}" == "1" ]]; then
  echo "Partner panel schema: multibot (table bots exists)"
  collision_mode="multibot"
else
  echo "Partner panel schema: legacy single-tenant (table bots missing)"
  collision_mode="legacy"
fi

python3 - "$OUT_DIR/source_subscriptions_keyset.csv" "$OUT_DIR/target_marzban_values.sql" "$collision_mode" "$TARGET_BOT_USERNAME" <<'PY'
import csv, sys
inp, out, mode, target_bot_username = sys.argv[1:5]
bot_sql = target_bot_username.replace("'", "''")
with open(inp, newline="") as f, open(out, "w") as w:
    rows = list(csv.DictReader(f))
    w.write("CREATE TEMPORARY TABLE st_marzban_usernames(username varchar(255));\n")
    for row in rows:
        username = row["marzban_username"].replace("'", "''")
        w.write(f"INSERT INTO st_marzban_usernames(username) VALUES ('{username}');\n")
    if mode == "multibot":
        w.write(
            "SELECT 'marzban_username_collisions' AS section, u.username, u.bot_id, b.username AS bot_username "
            "FROM users u JOIN st_marzban_usernames s ON s.username = u.username "
            "LEFT JOIN bots b ON b.id = u.bot_id "
            f"WHERE b.username IS NULL OR b.username <> '{bot_sql}' "
            "ORDER BY u.username LIMIT 200;\n"
        )
        w.write(
            f"SELECT 'marzban_username_collision_count' AS section, COUNT(*) AS value "
            "FROM users u JOIN st_marzban_usernames s ON s.username = u.username "
            "LEFT JOIN bots b ON b.id = u.bot_id "
            f"WHERE b.username IS NULL OR b.username <> '{bot_sql}';\n"
        )
    else:
        w.write(
            "SELECT 'legacy_username_matches' AS section, COUNT(*) AS value "
            "FROM users u JOIN st_marzban_usernames s ON s.username = u.username;\n"
        )
        w.write(
            "SELECT 'legacy_username_missing' AS section, COUNT(*) AS value "
            "FROM st_marzban_usernames s LEFT JOIN users u ON u.username = s.username "
            "WHERE u.id IS NULL;\n"
        )
PY
run_mysql "$PANEL_REF" "$panel_mysql_db" "$PANEL_MYSQL_CONTAINER" < "$OUT_DIR/target_marzban_values.sql" > "$OUT_DIR/target_marzban_collisions.txt"

echo "Audit complete: $OUT_DIR"

