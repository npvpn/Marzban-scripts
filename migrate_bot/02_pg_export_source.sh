#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

ensure_artifacts
RUN_ID="${RUN_ID:-$(timestamp)}"
OUT_DIR="$ARTIFACT_ROOT/$RUN_ID/pg_export"
mkdir -p "$OUT_DIR"

SOURCE_REF="${SOURCE_USER}@${SOURCE_HOST}"
source_pg_env_file="$OUT_DIR/source_pg_env.txt"
remote_pg_env "$SOURCE_REF" "$PG_CONTAINER" > "$source_pg_env_file"
pg_user="$(awk -F= '$1=="PGUSER"{print $2}' "$source_pg_env_file")"
pg_db="$(awk -F= '$1=="PGDATABASE"{print $2}' "$source_pg_env_file")"

echo "Export run: $RUN_ID"
echo "Output: $OUT_DIR"

export_query() {
  local table="$1"
  case "$table" in
    vpn_countries) echo "SELECT id,country_name,flag FROM vpn_countries ORDER BY id" ;;
    vpn_servers) echo "SELECT id,country_id,ip,keys_count,keys_limit,node_id,node_name FROM vpn_servers ORDER BY id" ;;
    currencies) echo "SELECT id,code,symbol,is_active FROM currencies ORDER BY id" ;;
    subscriptions_type) echo "SELECT id,period_days,sub_type,sort_order,is_active,devices_limit,public_name,description FROM subscriptions_type ORDER BY id" ;;
    subscription_prices) echo "SELECT sp.id,sp.subscription_type_id,sp.currency_id,c.code AS currency_code,sp.price,sp.is_active FROM subscription_prices sp LEFT JOIN currencies c ON c.id=sp.currency_id ORDER BY sp.id" ;;
    subscription_features) echo "SELECT id,subscription_type_id,sort_order FROM subscription_features ORDER BY id" ;;
    feature_translations) echo "SELECT feature_id,lang,title,description FROM feature_translations ORDER BY feature_id,lang" ;;
    users) echo "SELECT id,is_active,tg_user_id,ref_link,ref_tg_user_id,ref_buys,trial_expired,sent_ref_bonus,partner_system,full_name,username,created_at,utm_source,connect_url FROM users ORDER BY id" ;;
    user_messages) echo "SELECT id,tg_user_id,message_text,message_type,created_at,chat_id FROM user_messages ORDER BY id" ;;
    payments) echo "SELECT id,payment_provider,currency,total_amount,tg_user_id,tg_charge_id,provider_charge_id,purchase_type,created_at FROM payments ORDER BY id" ;;
    promo_codes) echo "SELECT id,code,discount_percent,promo_type,max_uses,times_used,is_active,present_sub_type FROM promo_codes ORDER BY id" ;;
    promo_usage_history) echo "SELECT id,tg_user_id,promo_code_id,used_at FROM promo_usage_history ORDER BY id" ;;
    partner_balance) echo "SELECT id,partner_id,tg_user_id,amount,created_at FROM partner_balance ORDER BY id" ;;
    subscriptions) echo "SELECT id,sub_type_id,payment_id,tg_user_id,server_id,created_at,date_end,last_location_change,is_active,used_vpn FROM subscriptions ORDER BY id" ;;
    wireguard_subscriptions) echo "SELECT id,subscription_id,public_key,endpoint,created_at FROM wireguard_subscriptions ORDER BY id" ;;
    recurring_yookassa) echo "SELECT id,sub_type_id,sub_id,tg_user_id,payment_method_id,created_at,last_payment_id,last_payment_date,last_idempotence_key,status,error_count,last_error_date,card_first6,card_last4 FROM recurring_yookassa ORDER BY id" ;;
    recurring_robokassa) echo "SELECT id,sub_type_id,sub_id,tg_user_id,first_invoice_id,created_at,last_invoice_id,last_payment_date,last_idempotence_key,status,error_count,last_error_date FROM recurring_robokassa ORDER BY id" ;;
    payments_messages) echo "SELECT id,chat_id,message_id,provider,invoice_id,date_end FROM payments_messages ORDER BY id" ;;
    mass_messages) echo "SELECT id,title,message,image_filename,created_at,status,recipient_count,success_count,error_count,filter_criteria FROM mass_messages ORDER BY id" ;;
    notification_templates) echo "SELECT id,segment_key,title,text,button_text,enabled,delay_minutes FROM notification_templates ORDER BY id" ;;
    text_messages) echo "SELECT id,key,default_text,current_text,updated_at,description,variables FROM text_messages ORDER BY id" ;;
    *) echo "Unknown table $table" >&2; return 1 ;;
  esac
}

tables=(
  vpn_countries vpn_servers currencies subscriptions_type subscription_prices subscription_features
  feature_translations users user_messages payments promo_codes promo_usage_history partner_balance
  subscriptions wireguard_subscriptions recurring_yookassa recurring_robokassa payments_messages
  mass_messages notification_templates text_messages
)

for table in "${tables[@]}"; do
  echo "Exporting $table"
  query="$(export_query "$table")"
  run_ssh "$SOURCE_REF" \
    "docker exec -i '$PG_CONTAINER' psql -v ON_ERROR_STOP=1 -U '$pg_user' -d '$pg_db' -c \"COPY ($query) TO STDOUT WITH CSV HEADER\"" \
    > "$OUT_DIR/$table.csv"
done

echo "Exporting audit-only legacy counts"
run_ssh "$SOURCE_REF" "docker exec -i '$PG_CONTAINER' psql -v ON_ERROR_STOP=1 -U '$pg_user' -d '$pg_db'" > "$OUT_DIR/legacy_excluded_counts.txt" <<'SQL'
SELECT 'connections' AS item, count(*) FROM connections;
SQL

echo "Copying source env files without printing contents"
run_ssh "$SOURCE_REF" "cd '$SOURCE_PATH' && tar -czf - .env .env.marzban 2>/dev/null || true" > "$OUT_DIR/source_env_files.tgz"

echo "Copying source message images (src/files → ${TARGET_BOT_ID}__* on import)"
fetch_source_files_tgz "$OUT_DIR/source_files.tgz" "$OUT_DIR/source_files_list.txt"

sha256sum "$OUT_DIR"/*.csv > "$OUT_DIR/SHA256SUMS"
echo "PG source export complete: $OUT_DIR"

