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

TARGET_REF="${TARGET_USER}@${TARGET_HOST}"
REMOTE_DIR="/tmp/vpnzab_pg_import_${TARGET_BOT_ID}"
CONTAINER_DIR="/tmp/vpnzab_pg_import_${TARGET_BOT_ID}"

if [[ "${SKIP_PG_IMPORT:-}" == "1" ]]; then
  echo "SKIP_PG_IMPORT=1 — skipping PostgreSQL import, copying message images only"
else
target_pg_env_file="$(mktemp)"
remote_pg_env "$TARGET_REF" "$PG_CONTAINER" > "$target_pg_env_file"
pg_user="$(awk -F= '$1=="PGUSER"{print $2}' "$target_pg_env_file")"
pg_db="$(awk -F= '$1=="PGDATABASE"{print $2}' "$target_pg_env_file")"
rm -f "$target_pg_env_file"

echo "Uploading CSV export to target: $REMOTE_DIR"
( cd "$EXPORT_DIR" && tar -czf - -- *.csv ) | run_ssh "$TARGET_REF" "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR' && tar -xzf - -C '$REMOTE_DIR'"
run_ssh "$TARGET_REF" "docker exec '$PG_CONTAINER' rm -rf '$CONTAINER_DIR' 2>/dev/null || true && docker cp '$REMOTE_DIR' '$PG_CONTAINER:$CONTAINER_DIR'"

echo "Running target PostgreSQL import for bot_id=$TARGET_BOT_ID server_id=$TARGET_SERVER_ID"
run_ssh "$TARGET_REF" "docker exec -i '$PG_CONTAINER' psql -v ON_ERROR_STOP=1 -v target_bot_id='$TARGET_BOT_ID' -v target_server_id='$TARGET_SERVER_ID' -v import_dir='$CONTAINER_DIR' -U '$pg_user' -d '$pg_db'" <<'SQL'
\pset pager off
\set subscriptions_type_csv :import_dir '/subscriptions_type.csv'
\set subscription_prices_csv :import_dir '/subscription_prices.csv'
\set subscription_features_csv :import_dir '/subscription_features.csv'
\set feature_translations_csv :import_dir '/feature_translations.csv'
\set users_csv :import_dir '/users.csv'
\set user_messages_csv :import_dir '/user_messages.csv'
\set payments_csv :import_dir '/payments.csv'
\set promo_codes_csv :import_dir '/promo_codes.csv'
\set promo_usage_history_csv :import_dir '/promo_usage_history.csv'
\set partner_balance_csv :import_dir '/partner_balance.csv'
\set subscriptions_csv :import_dir '/subscriptions.csv'
\set wireguard_subscriptions_csv :import_dir '/wireguard_subscriptions.csv'
\set recurring_yookassa_csv :import_dir '/recurring_yookassa.csv'
\set recurring_robokassa_csv :import_dir '/recurring_robokassa.csv'
\set payments_messages_csv :import_dir '/payments_messages.csv'
\set mass_messages_csv :import_dir '/mass_messages.csv'
\set notification_templates_csv :import_dir '/notification_templates.csv'
\set text_messages_csv :import_dir '/text_messages.csv'

SELECT EXISTS (SELECT 1 FROM bots WHERE id = :target_bot_id::bigint) AS target_bot_exists \gset
\if :target_bot_exists
\else
  \echo target bot does not exist
  \quit 3
\endif

BEGIN;
SET CONSTRAINTS ALL DEFERRED;

CREATE TEMP TABLE st_subscriptions_type (
  id bigint, period_days integer, sub_type varchar(24), sort_order integer, is_active boolean,
  devices_limit integer, public_name varchar(255), description text
);
CREATE TEMP TABLE st_subscription_prices (
  id bigint, subscription_type_id bigint, currency_id integer, currency_code varchar(16), price numeric(10,2), is_active boolean
);
CREATE TEMP TABLE st_subscription_features (
  id bigint, subscription_type_id bigint, sort_order integer
);
CREATE TEMP TABLE st_feature_translations (
  feature_id bigint, lang varchar(2), title varchar(255), description text
);
CREATE TEMP TABLE st_users (
  id bigint, is_active boolean, tg_user_id bigint, ref_link varchar(255), ref_tg_user_id bigint,
  ref_buys bigint, trial_expired boolean, sent_ref_bonus boolean, partner_system boolean,
  full_name varchar(120), username varchar(50), created_at timestamp,
  utm_source varchar(255), connect_url varchar(100)
);
CREATE TEMP TABLE st_user_messages (
  id integer, tg_user_id bigint, message_text text, message_type varchar(50), created_at timestamp, chat_id bigint
);
CREATE TEMP TABLE st_payments (
  id bigint, payment_provider varchar(40), currency varchar(3), total_amount bigint, tg_user_id bigint,
  tg_charge_id varchar(40), provider_charge_id varchar(50), purchase_type varchar(10), created_at timestamp
);
CREATE TEMP TABLE st_promo_codes (
  id bigint, code varchar(50), discount_percent integer, promo_type varchar(20), max_uses integer,
  times_used integer, is_active boolean, present_sub_type bigint
);
CREATE TEMP TABLE st_promo_usage_history (
  id bigint, tg_user_id bigint, promo_code_id bigint, used_at timestamp
);
CREATE TEMP TABLE st_partner_balance (
  id bigint, partner_id bigint, tg_user_id bigint, amount numeric(10,2), created_at timestamp
);
CREATE TEMP TABLE st_subscriptions (
  id bigint, sub_type_id integer, payment_id integer, tg_user_id bigint, server_id bigint,
  created_at timestamp, date_end timestamp, last_location_change timestamp, is_active boolean, used_vpn boolean
);
CREATE TEMP TABLE st_wireguard_subscriptions (
  id bigint, subscription_id bigint, public_key varchar(64), endpoint varchar(255), created_at timestamp
);
CREATE TEMP TABLE st_recurring_yookassa (
  id integer, sub_type_id integer, sub_id integer, tg_user_id bigint, payment_method_id varchar(128),
  created_at timestamp, last_payment_id varchar(128), last_payment_date timestamp, last_idempotence_key varchar(128),
  status varchar(20), error_count integer, last_error_date timestamp, card_first6 varchar(6), card_last4 varchar(4)
);
CREATE TEMP TABLE st_recurring_robokassa (
  id integer, sub_type_id integer, sub_id integer, tg_user_id bigint, first_invoice_id varchar(128),
  created_at timestamp, last_invoice_id varchar(128), last_payment_date timestamp, last_idempotence_key varchar(128),
  status varchar(20), error_count integer, last_error_date timestamp
);
CREATE TEMP TABLE st_payments_messages (
  id integer, chat_id bigint, message_id bigint, provider varchar(40), invoice_id varchar(128), date_end timestamp
);
CREATE TEMP TABLE st_mass_messages (
  id integer, title varchar(255), message text, image_filename varchar(255), created_at timestamptz, status varchar(20),
  recipient_count integer, success_count integer, error_count integer, filter_criteria json
);
CREATE TEMP TABLE st_notification_templates (
  id integer, segment_key varchar, title varchar, text text, button_text varchar, enabled boolean, delay_minutes integer
);
CREATE TEMP TABLE st_text_messages (
  id integer, key varchar(255), default_text text, current_text text, updated_at timestamptz,
  description text, variables json
);

COPY st_subscriptions_type FROM :'subscriptions_type_csv' WITH CSV HEADER;
COPY st_subscription_prices FROM :'subscription_prices_csv' WITH CSV HEADER;
COPY st_subscription_features FROM :'subscription_features_csv' WITH CSV HEADER;
COPY st_feature_translations FROM :'feature_translations_csv' WITH CSV HEADER;
COPY st_users FROM :'users_csv' WITH CSV HEADER;
COPY st_user_messages FROM :'user_messages_csv' WITH CSV HEADER;
COPY st_payments FROM :'payments_csv' WITH CSV HEADER;
COPY st_promo_codes FROM :'promo_codes_csv' WITH CSV HEADER;
COPY st_promo_usage_history FROM :'promo_usage_history_csv' WITH CSV HEADER;
COPY st_partner_balance FROM :'partner_balance_csv' WITH CSV HEADER;
COPY st_subscriptions FROM :'subscriptions_csv' WITH CSV HEADER;
COPY st_wireguard_subscriptions FROM :'wireguard_subscriptions_csv' WITH CSV HEADER;
COPY st_recurring_yookassa FROM :'recurring_yookassa_csv' WITH CSV HEADER;
COPY st_recurring_robokassa FROM :'recurring_robokassa_csv' WITH CSV HEADER;
COPY st_payments_messages FROM :'payments_messages_csv' WITH CSV HEADER;
COPY st_mass_messages FROM :'mass_messages_csv' WITH CSV HEADER;
COPY st_notification_templates FROM :'notification_templates_csv' WITH CSV HEADER;
COPY st_text_messages FROM :'text_messages_csv' WITH CSV HEADER;

CREATE TEMP TABLE map_users AS
SELECT id AS src_id, (SELECT COALESCE(MAX(id),0) FROM users) + row_number() OVER (ORDER BY id) AS new_id
FROM st_users;
CREATE TEMP TABLE map_sub_types AS
SELECT id AS src_id, (SELECT COALESCE(MAX(id),0) FROM subscriptions_type) + row_number() OVER (ORDER BY id) AS new_id
FROM st_subscriptions_type;
CREATE TEMP TABLE map_prices AS
SELECT id AS src_id, (SELECT COALESCE(MAX(id),0) FROM subscription_prices) + row_number() OVER (ORDER BY id) AS new_id
FROM st_subscription_prices;
CREATE TEMP TABLE map_features AS
SELECT id AS src_id, (SELECT COALESCE(MAX(id),0) FROM subscription_features) + row_number() OVER (ORDER BY id) AS new_id
FROM st_subscription_features;
CREATE TEMP TABLE map_payments AS
SELECT id AS src_id, (SELECT COALESCE(MAX(id),0) FROM payments) + row_number() OVER (ORDER BY id) AS new_id
FROM st_payments;
CREATE TEMP TABLE map_promo_codes AS
SELECT id AS src_id, (SELECT COALESCE(MAX(id),0) FROM promo_codes) + row_number() OVER (ORDER BY id) AS new_id
FROM st_promo_codes;
CREATE TEMP TABLE map_partner_balance AS
SELECT id AS src_id, (SELECT COALESCE(MAX(id),0) FROM partner_balance) + row_number() OVER (ORDER BY id) AS new_id
FROM st_partner_balance;
CREATE TEMP TABLE map_user_messages AS
SELECT id AS src_id, (SELECT COALESCE(MAX(id),0) FROM user_messages) + row_number() OVER (ORDER BY id) AS new_id
FROM st_user_messages;
CREATE TEMP TABLE map_wg AS
SELECT id AS src_id, (SELECT COALESCE(MAX(id),0) FROM wireguard_subscriptions) + row_number() OVER (ORDER BY id) AS new_id
FROM st_wireguard_subscriptions;
CREATE TEMP TABLE map_rec_yk AS
SELECT id AS src_id, (SELECT COALESCE(MAX(id),0) FROM recurring_yookassa) + row_number() OVER (ORDER BY id) AS new_id
FROM st_recurring_yookassa;
CREATE TEMP TABLE map_rec_rb AS
SELECT id AS src_id, (SELECT COALESCE(MAX(id),0) FROM recurring_robokassa) + row_number() OVER (ORDER BY id) AS new_id
FROM st_recurring_robokassa;
CREATE TEMP TABLE map_pay_msg AS
SELECT id AS src_id, (SELECT COALESCE(MAX(id),0) FROM payments_messages) + row_number() OVER (ORDER BY id) AS new_id
FROM st_payments_messages;
CREATE TEMP TABLE map_mass AS
SELECT id AS src_id, (SELECT COALESCE(MAX(id),0) FROM mass_messages) + row_number() OVER (ORDER BY id) AS new_id
FROM st_mass_messages;
CREATE TEMP TABLE map_notif AS
SELECT id AS src_id, (SELECT COALESCE(MAX(id),0) FROM notification_templates) + row_number() OVER (ORDER BY id) AS new_id
FROM st_notification_templates;
CREATE TEMP TABLE map_text AS
SELECT id AS src_id, (SELECT COALESCE(MAX(id),0) FROM text_messages) + row_number() OVER (ORDER BY id) AS new_id
FROM st_text_messages;

SELECT EXISTS (SELECT 1 FROM users u JOIN st_users s ON u.bot_id = :target_bot_id::bigint AND u.tg_user_id = s.tg_user_id) AS users_conflict \gset
\if :users_conflict
  \echo users conflict for target bot
  \quit 4
\endif
SELECT EXISTS (SELECT 1 FROM st_subscription_prices WHERE COALESCE(NULLIF(BTRIM(currency_code), ''), NULL) IS NULL) AS prices_missing_currency_code \gset
\if :prices_missing_currency_code
  \echo subscription_prices contains empty currency_code values
  \quit 8
\endif
SELECT EXISTS (
  SELECT 1
  FROM st_subscription_prices s
  LEFT JOIN currencies c ON UPPER(c.code) = UPPER(BTRIM(s.currency_code))
  WHERE c.id IS NULL
) AS prices_unknown_currency_code \gset
\if :prices_unknown_currency_code
  \echo target currencies table does not contain one or more source currency_code values
  \quit 9
\endif
SELECT EXISTS (SELECT 1 FROM subscriptions t JOIN st_subscriptions s ON t.bot_id = :target_bot_id::bigint AND t.id = s.id) AS subscriptions_conflict \gset
\if :subscriptions_conflict
  \echo subscriptions.id conflict for target bot
  \quit 5
\endif

INSERT INTO subscriptions_type (
  id, bot_id, period_days, sub_type, sort_order, is_active, devices_limit, public_name, description,
  user_limit, is_extended, matrix_id, matrix_version, matrix_cell
)
SELECT m.new_id, :target_bot_id::bigint, s.period_days, s.sub_type, COALESCE(s.sort_order,0), COALESCE(s.is_active,true),
       COALESCE(s.devices_limit,1), s.public_name, s.description, NULL, false, NULL, NULL, NULL
FROM st_subscriptions_type s JOIN map_sub_types m ON m.src_id = s.id;

INSERT INTO subscription_prices (id, bot_id, subscription_type_id, currency_id, price, is_active)
SELECT m.new_id, :target_bot_id::bigint, mt.new_id, c.id, s.price, COALESCE(s.is_active,true)
FROM st_subscription_prices s
JOIN map_prices m ON m.src_id = s.id
JOIN map_sub_types mt ON mt.src_id = s.subscription_type_id
JOIN currencies c ON UPPER(c.code) = UPPER(BTRIM(s.currency_code));

INSERT INTO subscription_features (id, bot_id, subscription_type_id, sort_order)
SELECT m.new_id, :target_bot_id::bigint, mt.new_id, COALESCE(s.sort_order,0)
FROM st_subscription_features s
JOIN map_features m ON m.src_id = s.id
JOIN map_sub_types mt ON mt.src_id = s.subscription_type_id;

INSERT INTO feature_translations (feature_id, bot_id, lang, title, description)
SELECT mf.new_id, :target_bot_id::bigint, s.lang, s.title, s.description
FROM st_feature_translations s JOIN map_features mf ON mf.src_id = s.feature_id;

INSERT INTO users (
  id, bot_id, is_active, tg_user_id, ref_link, ref_tg_user_id, ref_buys, trial_expired, sent_ref_bonus,
  partner_system, full_name, username, email, language, created_at, utm_source, connect_url, phone, auth_source
)
SELECT m.new_id, :target_bot_id::bigint, COALESCE(s.is_active,true), s.tg_user_id, s.ref_link, s.ref_tg_user_id,
       COALESCE(s.ref_buys,0), COALESCE(s.trial_expired,false), COALESCE(s.sent_ref_bonus,false),
       COALESCE(s.partner_system,false), s.full_name, s.username, NULL, NULL, s.created_at, s.utm_source,
       s.connect_url, NULL, 'telegram'
FROM st_users s JOIN map_users m ON m.src_id = s.id;

INSERT INTO payments (
  id, bot_id, payment_provider, currency, total_amount, tg_user_id, tg_charge_id, provider_charge_id,
  purchase_type, status, subscription_id, subscription_payment_number, created_at
)
SELECT m.new_id, :target_bot_id::bigint, s.payment_provider, s.currency, s.total_amount, s.tg_user_id,
       s.tg_charge_id, s.provider_charge_id, s.purchase_type, 'completed', NULL, NULL, s.created_at
FROM st_payments s JOIN map_payments m ON m.src_id = s.id;

INSERT INTO subscriptions (
  id, bot_id, sub_type_id, payment_id, tg_user_id, server_id, created_at, date_end,
  last_location_change, is_active, used_vpn
)
SELECT s.id, :target_bot_id::bigint, mt.new_id, mp.new_id, s.tg_user_id, :target_server_id::bigint,
       s.created_at, s.date_end, s.last_location_change, COALESCE(s.is_active,true), COALESCE(s.used_vpn,false)
FROM st_subscriptions s
JOIN map_sub_types mt ON mt.src_id = s.sub_type_id
LEFT JOIN map_payments mp ON mp.src_id = s.payment_id;

WITH rel AS (
  SELECT mp.new_id AS payment_id, s.id AS subscription_id, s.tg_user_id, s.created_at
  FROM st_subscriptions s JOIN map_payments mp ON mp.src_id = s.payment_id
), numbered AS (
  SELECT payment_id, subscription_id,
         row_number() OVER (PARTITION BY :target_bot_id::bigint, tg_user_id, subscription_id ORDER BY created_at, payment_id) AS rn
  FROM rel
)
UPDATE payments p
SET subscription_id = n.subscription_id,
    subscription_payment_number = n.rn
FROM numbered n
WHERE p.id = n.payment_id AND p.bot_id = :target_bot_id::bigint;

INSERT INTO promo_codes (id, bot_id, code, discount_percent, promo_type, max_uses, times_used, owner_id, is_active, present_sub_type)
SELECT m.new_id, :target_bot_id::bigint, s.code, COALESCE(s.discount_percent,0), s.promo_type,
       COALESCE(s.max_uses,1), COALESCE(s.times_used,0), NULL, COALESCE(s.is_active,true), mt.new_id
FROM st_promo_codes s
JOIN map_promo_codes m ON m.src_id = s.id
LEFT JOIN map_sub_types mt ON mt.src_id = s.present_sub_type;

INSERT INTO promo_usage_history (id, bot_id, tg_user_id, promo_code_id, used_at)
SELECT s.id, :target_bot_id::bigint, s.tg_user_id, mpc.new_id, s.used_at
FROM st_promo_usage_history s JOIN map_promo_codes mpc ON mpc.src_id = s.promo_code_id;

INSERT INTO partner_balance (id, bot_id, partner_id, tg_user_id, amount, created_at)
SELECT mb.new_id, :target_bot_id::bigint, mu.new_id, s.tg_user_id, s.amount, s.created_at
FROM st_partner_balance s
JOIN map_partner_balance mb ON mb.src_id = s.id
JOIN map_users mu ON mu.src_id = s.partner_id;

INSERT INTO wireguard_subscriptions (id, bot_id, subscription_id, public_key, endpoint, created_at)
SELECT mw.new_id, :target_bot_id::bigint, s.subscription_id, s.public_key, s.endpoint, s.created_at
FROM st_wireguard_subscriptions s JOIN map_wg mw ON mw.src_id = s.id;

INSERT INTO recurring_yookassa (
  id, bot_id, sub_type_id, sub_id, tg_user_id, payment_method_id, created_at, last_payment_id,
  last_payment_date, last_idempotence_key, status, error_count, last_error_date, card_first6, card_last4
)
SELECT m.new_id, :target_bot_id::bigint, mt.new_id, s.sub_id, s.tg_user_id, s.payment_method_id, s.created_at,
       s.last_payment_id, s.last_payment_date, s.last_idempotence_key, COALESCE(s.status,'active'),
       COALESCE(s.error_count,0), s.last_error_date, s.card_first6, s.card_last4
FROM st_recurring_yookassa s
JOIN map_rec_yk m ON m.src_id = s.id
JOIN map_sub_types mt ON mt.src_id = s.sub_type_id;

INSERT INTO recurring_robokassa (
  id, bot_id, sub_type_id, sub_id, tg_user_id, first_invoice_id, created_at, last_invoice_id,
  last_payment_date, last_idempotence_key, status, error_count, last_error_date
)
SELECT m.new_id, :target_bot_id::bigint, mt.new_id, s.sub_id, s.tg_user_id, s.first_invoice_id, s.created_at,
       s.last_invoice_id, s.last_payment_date, s.last_idempotence_key, COALESCE(s.status,'active'),
       COALESCE(s.error_count,0), s.last_error_date
FROM st_recurring_robokassa s
JOIN map_rec_rb m ON m.src_id = s.id
JOIN map_sub_types mt ON mt.src_id = s.sub_type_id;

INSERT INTO user_messages (id, bot_id, tg_user_id, message_text, message_type, created_at, chat_id)
SELECT m.new_id, :target_bot_id::bigint, s.tg_user_id, s.message_text, s.message_type, s.created_at, s.chat_id
FROM st_user_messages s JOIN map_user_messages m ON m.src_id = s.id;

INSERT INTO payments_messages (id, bot_id, chat_id, message_id, provider, invoice_id, date_end)
SELECT m.new_id, :target_bot_id::bigint, s.chat_id, s.message_id, s.provider, s.invoice_id, s.date_end
FROM st_payments_messages s JOIN map_pay_msg m ON m.src_id = s.id;

INSERT INTO mass_messages (id, bot_id, title, message, image_filename, created_at, status, recipient_count, success_count, error_count, filter_criteria)
SELECT m.new_id, :target_bot_id::bigint, s.title, s.message,
  CASE
    WHEN s.image_filename IS NULL OR BTRIM(s.image_filename) = '' THEN NULL
    ELSE :target_bot_id::text || '__' || regexp_replace(regexp_replace(BTRIM(s.image_filename), '^.*/', ''), '^\d+__', '')
  END,
  s.created_at,
       s.status::massmessagestatus, COALESCE(s.recipient_count,0), COALESCE(s.success_count,0),
       COALESCE(s.error_count,0), s.filter_criteria
FROM st_mass_messages s JOIN map_mass m ON m.src_id = s.id;

INSERT INTO notification_templates (bot_id, segment_key, title, text, button_text, enabled, delay_minutes)
SELECT :target_bot_id::bigint, s.segment_key, s.title, s.text, s.button_text, COALESCE(s.enabled,true), s.delay_minutes
FROM st_notification_templates s
ON CONFLICT (bot_id, segment_key) DO UPDATE SET
  title = EXCLUDED.title,
  text = EXCLUDED.text,
  button_text = EXCLUDED.button_text,
  enabled = EXCLUDED.enabled,
  delay_minutes = EXCLUDED.delay_minutes;

INSERT INTO text_messages (bot_id, key, default_text, current_text, updated_at, description, variables)
SELECT :target_bot_id::bigint, s.key, s.default_text, s.current_text, s.updated_at, s.description, s.variables
FROM st_text_messages s
ON CONFLICT (bot_id, key) DO UPDATE SET
  default_text = EXCLUDED.default_text,
  current_text = EXCLUDED.current_text,
  updated_at = EXCLUDED.updated_at,
  description = EXCLUDED.description,
  variables = EXCLUDED.variables;

INSERT INTO bot_settings (bot_id, data)
SELECT :target_bot_id::bigint, '{}'::jsonb
WHERE NOT EXISTS (SELECT 1 FROM bot_settings WHERE bot_id = :target_bot_id::bigint);

DO $$
DECLARE
  r record;
  seq_name text;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('users','id'),
      ('subscriptions_type','id'),
      ('subscription_prices','id'),
      ('subscription_features','id'),
      ('payments','id'),
      ('promo_codes','id'),
      ('partner_balance','id'),
      ('user_messages','id'),
      ('wireguard_subscriptions','id'),
      ('recurring_yookassa','id'),
      ('recurring_robokassa','id'),
      ('payments_messages','id'),
      ('mass_messages','id'),
      ('notification_templates','id'),
      ('text_messages','id')
    ) AS v(table_name, column_name)
  LOOP
    seq_name := pg_get_serial_sequence(r.table_name, r.column_name);
    IF seq_name IS NOT NULL THEN
      EXECUTE format(
        'SELECT setval(%L::regclass, GREATEST((SELECT COALESCE(MAX(%I),1) FROM %I),1), true)',
        seq_name,
        r.column_name,
        r.table_name
      );
    END IF;
  END LOOP;
END $$;

COMMIT;

SELECT 'imported_users' AS metric, count(*) FROM users WHERE bot_id = :target_bot_id::bigint
UNION ALL SELECT 'imported_subscriptions', count(*) FROM subscriptions WHERE bot_id = :target_bot_id::bigint
UNION ALL SELECT 'imported_payments', count(*) FROM payments WHERE bot_id = :target_bot_id::bigint
UNION ALL SELECT 'payments_without_subscription', count(*) FROM payments WHERE bot_id = :target_bot_id::bigint AND subscription_id IS NULL;
SQL

echo "Target PostgreSQL import complete."
fi

FILES_TGZ="$EXPORT_DIR/source_files.tgz"
if [[ ! -s "$FILES_TGZ" ]]; then
  echo "source_files.tgz missing or empty — fetching message images from source now"
  fetch_source_files_tgz "$FILES_TGZ" "$EXPORT_DIR/source_files_list.txt"
fi
copy_prefixed_bot_files_to_target "$FILES_TGZ" "$EXPORT_DIR/files_rename_manifest.json"

