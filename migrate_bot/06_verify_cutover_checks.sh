#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

ensure_artifacts
RUN_ID="${RUN_ID:-$(timestamp)}"
OUT_DIR="$ARTIFACT_ROOT/$RUN_ID/verify"
mkdir -p "$OUT_DIR"

TARGET_REF="${TARGET_USER}@${TARGET_HOST}"
PANEL_REF="${PANEL_USER}@${PANEL_HOST}"
target_pg_env_file="$OUT_DIR/target_pg_env.txt"
panel_mysql_env_file="$OUT_DIR/panel_mysql_env.txt"
remote_pg_env "$TARGET_REF" "$PG_CONTAINER" > "$target_pg_env_file"
remote_panel_mysql_env > "$panel_mysql_env_file"
pg_user="$(awk -F= '$1=="PGUSER"{print $2}' "$target_pg_env_file")"
pg_db="$(awk -F= '$1=="PGDATABASE"{print $2}' "$target_pg_env_file")"
mysql_db="$(awk -F= '$1=="MYSQL_DATABASE"{print $2}' "$panel_mysql_env_file")"
require_partner_multibot_schema "$mysql_db"

echo "Running target PG verification"
run_ssh "$TARGET_REF" "docker exec -i '$PG_CONTAINER' psql -v ON_ERROR_STOP=1 -U '$pg_user' -d '$pg_db'" > "$OUT_DIR/target_pg_verify.txt" <<SQL
\pset pager off
SELECT 'bot' AS section, id, username, public_name, domain FROM bots WHERE id=${TARGET_BOT_ID};
SELECT 'counts' AS section, 'users' AS table_name, count(*) FROM users WHERE bot_id=${TARGET_BOT_ID}
UNION ALL SELECT 'counts','subscriptions',count(*) FROM subscriptions WHERE bot_id=${TARGET_BOT_ID}
UNION ALL SELECT 'counts','payments',count(*) FROM payments WHERE bot_id=${TARGET_BOT_ID}
UNION ALL SELECT 'counts','subscriptions_type',count(*) FROM subscriptions_type WHERE bot_id=${TARGET_BOT_ID}
UNION ALL SELECT 'counts','subscription_prices',count(*) FROM subscription_prices WHERE bot_id=${TARGET_BOT_ID}
UNION ALL SELECT 'counts','recurring_yookassa',count(*) FROM recurring_yookassa WHERE bot_id=${TARGET_BOT_ID}
UNION ALL SELECT 'counts','recurring_robokassa',count(*) FROM recurring_robokassa WHERE bot_id=${TARGET_BOT_ID}
UNION ALL SELECT 'counts','partner_balance',count(*) FROM partner_balance WHERE bot_id=${TARGET_BOT_ID}
UNION ALL SELECT 'counts','notification_templates',count(*) FROM notification_templates WHERE bot_id=${TARGET_BOT_ID}
UNION ALL SELECT 'counts','text_messages',count(*) FROM text_messages WHERE bot_id=${TARGET_BOT_ID}
UNION ALL SELECT 'counts','promo_codes',count(*) FROM promo_codes WHERE bot_id=${TARGET_BOT_ID}
ORDER BY table_name;
SELECT 'fk_missing_users_subscriptions' AS section, count(*) FROM subscriptions s LEFT JOIN users u ON u.bot_id=s.bot_id AND u.tg_user_id=s.tg_user_id WHERE s.bot_id=${TARGET_BOT_ID} AND u.id IS NULL;
SELECT 'fk_missing_users_payments' AS section, count(*) FROM payments p LEFT JOIN users u ON u.bot_id=p.bot_id AND u.tg_user_id=p.tg_user_id WHERE p.bot_id=${TARGET_BOT_ID} AND u.id IS NULL;
SELECT 'subscription_prices_missing_currency' AS section, count(*) FROM subscription_prices sp LEFT JOIN currencies c ON c.id=sp.currency_id WHERE sp.bot_id=${TARGET_BOT_ID} AND c.id IS NULL;
SELECT 'subscription_prices_rub_rows' AS section, count(*) FROM subscription_prices sp JOIN currencies c ON c.id=sp.currency_id WHERE sp.bot_id=${TARGET_BOT_ID} AND UPPER(c.code)='RUB';
SELECT 'recurring_yookassa_unlinked_without_date' AS section, count(*) FROM recurring_yookassa WHERE bot_id=${TARGET_BOT_ID} AND status='unlinked' AND unlinked_at IS NULL;
SELECT 'recurring_robokassa_unlinked_without_date' AS section, count(*) FROM recurring_robokassa WHERE bot_id=${TARGET_BOT_ID} AND status='unlinked' AND unlinked_at IS NULL;
SELECT 'promo_present_sub_type_fk_missing' AS section, count(*) FROM promo_codes p LEFT JOIN subscriptions_type st ON st.id=p.present_sub_type AND st.bot_id=p.bot_id WHERE p.bot_id=${TARGET_BOT_ID} AND p.present_sub_type IS NOT NULL AND st.id IS NULL;
SELECT 'payments_without_subscription' AS section, count(*) FROM payments WHERE bot_id=${TARGET_BOT_ID} AND subscription_id IS NULL;
SELECT 'wrong_server_id' AS section, count(*) FROM subscriptions WHERE bot_id=${TARGET_BOT_ID} AND COALESCE(server_id,-1) <> ${TARGET_SERVER_ID};
SELECT 'duplicate_subscription_ids' AS section, id, count(*) FROM subscriptions WHERE bot_id=${TARGET_BOT_ID} GROUP BY id HAVING count(*) > 1 LIMIT 20;
SELECT 'duplicate_users' AS section, tg_user_id, count(*) FROM users WHERE bot_id=${TARGET_BOT_ID} GROUP BY tg_user_id HAVING count(*) > 1 LIMIT 20;
SQL

echo "Running source partner-panel MySQL verification"
run_ssh "$PANEL_REF" "docker exec -i '$PANEL_MYSQL_CONTAINER' sh -lc 'if [ -n \"\${MYSQL_ROOT_PASSWORD:-}\" ]; then mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" \"$mysql_db\"; else mysql \"$mysql_db\"; fi'" > "$OUT_DIR/target_marzban_verify.txt" <<SQL
SELECT 'panel_bot' AS section, id, username, title FROM bots WHERE username='${TARGET_BOT_USERNAME}';
SELECT 'users_for_bot' AS section, COUNT(*) AS value FROM users u JOIN bots b ON b.id=u.bot_id WHERE b.username='${TARGET_BOT_USERNAME}';
SELECT 'missing_tokens' AS section, COUNT(*) AS value FROM users u JOIN bots b ON b.id=u.bot_id WHERE b.username='${TARGET_BOT_USERNAME}' AND (u.subscription_token IS NULL OR u.subscription_token='');
SELECT 'users_without_proxy' AS section, COUNT(*) AS value FROM users u JOIN bots b ON b.id=u.bot_id LEFT JOIN proxies p ON p.user_id=u.id WHERE b.username='${TARGET_BOT_USERNAME}' AND p.id IS NULL;
SELECT 'users_with_bs_extra' AS section, COUNT(*) AS value FROM users u JOIN bots b ON b.id=u.bot_id WHERE b.username='${TARGET_BOT_USERNAME}' AND COALESCE(u.bs_extra,0) > 0;
SELECT 'users_without_bot_id' AS section, COUNT(*) AS value FROM users WHERE bot_id IS NULL;
SELECT 'host_associations' AS section, COUNT(*) AS value FROM host_bot_association hba JOIN bots b ON b.id=hba.bot_id WHERE b.username='${TARGET_BOT_USERNAME}';
SELECT 'username_duplicates' AS section, username, COUNT(*) AS value FROM users GROUP BY username HAVING COUNT(*) > 1 LIMIT 20;
SQL

echo "Verification files:"
printf '%s\n' "$OUT_DIR/target_pg_verify.txt" "$OUT_DIR/target_marzban_verify.txt"

