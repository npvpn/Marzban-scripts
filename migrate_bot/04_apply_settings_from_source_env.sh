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
PAYMENT_SQL="$OUT_DIR/payment_settings.sql"
chmod 600 "$SETTINGS_JSON" "$PANEL_JSON" "$PAYMENT_SQL" 2>/dev/null || true

python3 - "$TMP_ENV_DIR" "$SETTINGS_JSON" "$PANEL_JSON" "$PAYMENT_SQL" "$TARGET_BOT_ID" <<'PY'
import json, shlex, sys
from pathlib import Path

env_dir, settings_out, panel_out, payment_sql_out, bot_id = sys.argv[1:]

def parse_env(path: Path) -> dict:
    data = {}
    if not path.exists():
        return data
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if (value.startswith("'") and value.endswith("'")) or (value.startswith('"') and value.endswith('"')):
            try:
                value = shlex.split(value)[0]
            except Exception:
                value = value[1:-1]
        data[key] = value
    return data

env = {}
env.update(parse_env(Path(env_dir) / ".env"))
env.update(parse_env(Path(env_dir) / ".env.marzban"))

def s(name, default=""):
    return env.get(name, default)

def b(name, default=False):
    raw = str(env.get(name, str(default))).strip().lower()
    return raw in {"1", "true", "yes", "on", "y"}

def i(name, default=0):
    try:
        return int(str(env.get(name, default)).strip())
    except Exception:
        return default

bot_settings_patch = {
    "support_link": s("TG_SUPPORT_LINK", ""),
    "private_mode": b("PRIVATE_MODE", False),
    "personalize": {
        "service_name": s("SERVICE_NAME", s("BOT_NAME", "VPN Service")),
        "thumbnail_url": s("THUMBNAIL_URL", ""),
        "thumbnail_image_path": s("THUMBNAIL_IMAGE_PATH", ""),
        "keys_left": i("KEYS_LEFT_NOTIFICATION", 3),
        "devices_limit_per_subscription": i("DEVICES_LIMIT_PER_SUBSCRIPTION", 3),
        "available_locations": s("AVAILABLE_LOCATIONS", ""),
        "show_info": s("SHOW_INFO", ""),
    },
    "trial_params": {
        "days": i("TRIAL_DAYS", 7),
        "change_country_delay": i("CHANGE_COUNTRY_DELAY_IN_DAYS", 1),
        "trial_enable": b("FREE_TRIAL_ENABLE", True),
        "paid_trial_enable": b("PAID_TRIAL_ENABLE", False),
        "change_paid_trial": i("CHANGE_PAID_TRIAL", 9),
        "channel_check_enabled": b("TRIAL_CHANNEL_CHECK_ENABLED", False),
        "channel_username": s("TRIAL_CHANNEL_USERNAME", ""),
    },
    "partner_system": {
        "enabled": b("PARTNER_SYSTEM_ENABLED", False),
        "on_startup": b("PARTNER_SYSTEM_ON_STARTUP", False),
        "first_purchase_percent": i("PARTNER_FIRST_PURCHASE_PERCENT", 20),
        "repeat_purchase_percent": i("PARTNER_REPEAT_PURCHASE_PERCENT", 10),
    },
    "device_management": {"enabled": b("DEVICE_MANAGEMENT_ENABLED", False)},
    "web_frontend": {"enabled": False, "domain": "", "telegram_login_domain": ""},
    "tariff_matrix": {"enabled": False},
}

panel_settings = {
    "sub_update_interval": str(s("SUB_UPDATE_INTERVAL", "12")),
    "sub_support_url": s("SUB_SUPPORT_URL", "https://t.me/"),
    "sub_profile_title": s("SUB_PROFILE_TITLE", "Subscription"),
    "sub_routing_happ": s("SUB_ROUTING_HAPP", ""),
    "sub_routing_v2raytun": s("SUB_ROUTING_V2RAYTUN", ""),
    "sub_client_note": s("SUB_CLIENT_NOTE", ""),
    "sub_profile_url": s("SUB_PROFILE_URL", ""),
    "bot_url": s("BOT_URL", ""),
    "sub_revoked_announce_text": s("SUB_REVOKED_ANNOUNCE_TEXT", ""),
    "sub_expired_announce_text": s("SUB_EXPIRED_ANNOUNCE_TEXT", ""),
    "sub_device_limit_announce_text": s("SUB_DEVICE_LIMIT_ANNOUNCE_TEXT", ""),
    "sub_unsupported_client_announce_text": s("SUB_UNSUPPORTED_CLIENT_ANNOUNCE_TEXT", ""),
    "sub_revoked_server_text": [x.strip() for x in s("SUB_REVOKED_SERVER_TEXT", "Эта ссылка не активна, Обновите ссылку в боте").split(",") if x.strip()],
    "sub_expired_server_text": [x.strip() for x in s("SUB_EXPIRED_SERVER_TEXT", "Подписка истекла, Продлите подписку в боте").split(",") if x.strip()],
    "sub_device_limit_server_text": [x.strip() for x in s("SUB_DEVICE_LIMIT_SERVER_TEXT", "Достигнут лимит устройств, Удалите старое устройство").split(",") if x.strip()],
    "sub_unsupported_client_server_text": [x.strip() for x in s("SUB_UNSUPPORTED_CLIENT_SERVER_TEXT", "Это приложение не поддерживается, Установите другое").split(",") if x.strip()],
}

Path(settings_out).write_text(json.dumps(bot_settings_patch, ensure_ascii=False, indent=2))
Path(panel_out).write_text(json.dumps(panel_settings, ensure_ascii=False, indent=2))

def sql_str(value):
    if value is None:
        return "NULL"
    return "'" + str(value).replace("'", "''") + "'"

sql = []
sql.append("BEGIN;")
sql.append(f"INSERT INTO bot_payment_settings (bot_id) VALUES ({bot_id}) ON CONFLICT (bot_id) DO NOTHING;")
sql.append(f"WITH inserted AS (INSERT INTO bot_yookassa_settings (enable, provider_token, vat_code, external, recurrent, allow_unlink, api_token, shop_id, paycheck_email, timeout_ms) VALUES ({str(b('YOO_KASSA_ENABLE', False)).lower()}, {sql_str(s('YOO_KASSA_PROVIDER_TOKEN', ''))}, {i('YOO_KASSA_NDS', 1)}, {str(b('YOO_KASSA_EXTERNAL', False)).lower()}, {str(b('YOO_KASSA_RECCURENT', False)).lower()}, {str(b('YOO_KASSA_ALLOW_UNLINK', False)).lower()}, {sql_str(s('YOO_KASSA_API_TOKEN', ''))}, {i('YOO_KASSA_SHOP_ID', 0)}, {sql_str(s('EMAIL_PAYCHECK', ''))}, {i('YOO_KASSA_TIMEOUT_MS', 15000)}) RETURNING id) UPDATE bot_payment_settings SET yookassa_settings_id=(SELECT id FROM inserted) WHERE bot_id={bot_id};")
sql.append(f"WITH inserted AS (INSERT INTO bot_aaio_settings (enable, host, api_key, shop_id, secret_key_one, secret_key_two, secret_key_webhook) VALUES ({str(b('AAIO_ENABLE', False)).lower()}, {sql_str(s('AAIO_HOST', ''))}, {sql_str(s('AAIO_API_KEY', ''))}, {sql_str(s('AAIO_SHOP_ID', ''))}, {sql_str(s('AAIO_SECRET_ONE', ''))}, {sql_str(s('AAIO_SECRET_TWO', ''))}, {sql_str(s('AAIO_SECRET_KEY_WEBHOOK', ''))}) RETURNING id) UPDATE bot_payment_settings SET aaio_settings_id=(SELECT id FROM inserted) WHERE bot_id={bot_id};")
sql.append(f"WITH inserted AS (INSERT INTO bot_lava_settings (enable, shop_id, secret_key, second_secret_key) VALUES ({str(b('LAVA_ENABLE', False)).lower()}, {sql_str(s('LAVA_SHOP_ID', ''))}, {sql_str(s('LAVA_SECRET_KEY', ''))}, {sql_str(s('LAVA_SECOND_SECRET_KEY', ''))}) RETURNING id) UPDATE bot_payment_settings SET lava_settings_id=(SELECT id FROM inserted) WHERE bot_id={bot_id};")
sql.append(f"WITH inserted AS (INSERT INTO bot_cryptobot_settings (enabled, token) VALUES ({str(b('CRYPTO_ENABLED', False)).lower()}, {sql_str(s('CRYPTO_BOT_API_TOKEN', ''))}) RETURNING id) UPDATE bot_payment_settings SET cryptobot_settings_id=(SELECT id FROM inserted) WHERE bot_id={bot_id};")
sql.append(f"WITH inserted AS (INSERT INTO bot_robokassa_settings (enable, merchant_login, password_1, password_2, test_password_1, test_password_2, test_mode) VALUES ({str(b('ROBOKASSA_ENABLE', False)).lower()}, {sql_str(s('ROBOKASSA_MERCHANT_LOGIN', ''))}, {sql_str(s('ROBOKASSA_PASSWORD_1', ''))}, {sql_str(s('ROBOKASSA_PASSWORD_2', ''))}, {sql_str(s('ROBOKASSA_TEST_PASSWORD_1', ''))}, {sql_str(s('ROBOKASSA_TEST_PASSWORD_2', ''))}, {str(b('ROBOKASSA_TEST_MODE', False)).lower()}) RETURNING id) UPDATE bot_payment_settings SET robokassa_settings_id=(SELECT id FROM inserted) WHERE bot_id={bot_id};")
sql.append(f"WITH inserted AS (INSERT INTO bot_cryptomus_settings (enabled, merchant_uuid, mode, api_key) VALUES ({str(b('CRYPTOMUS_ENABLED', False)).lower()}, {sql_str(s('CRYPTOMUS_MERCHANT_UUID', ''))}, {sql_str(s('CRYPTOMUS_MODE', 'heleket'))}, {sql_str(s('CRYPTOMUS_API_KEY', ''))}) RETURNING id) UPDATE bot_payment_settings SET cryptomus_settings_id=(SELECT id FROM inserted) WHERE bot_id={bot_id};")
sql.append(f"WITH inserted AS (INSERT INTO bot_cryptocloud_settings (enabled, api_key, shop_id, secret) VALUES ({str(b('CCLOUD_ENABLE', False)).lower()}, {sql_str(s('CCLOUD_API_KEY', ''))}, {sql_str(s('CCLOUD_SHOP_ID', ''))}, {sql_str(s('CCLOUD_SECRET', ''))}) RETURNING id) UPDATE bot_payment_settings SET cryptocloud_settings_id=(SELECT id FROM inserted) WHERE bot_id={bot_id};")
sql.append("COMMIT;")
Path(payment_sql_out).write_text("\n".join(sql) + "\n")
PY

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

echo "Applying panel bot and panel bot_settings to source partner panel MySQL"
panel_mysql_env_file="$OUT_DIR/panel_mysql_env.txt"
remote_panel_mysql_env > "$panel_mysql_env_file"
panel_mysql_db="$(awk -F= '$1=="MYSQL_DATABASE"{print $2}' "$panel_mysql_env_file")"
apply_panel_bot_settings_json "$PANEL_JSON" "$PANEL_REF" "$TARGET_BOT_USERNAME" "$panel_mysql_db" "$PANEL_MYSQL_CONTAINER"

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
match = re.search(r"INSERT INTO `jwt` VALUES \(1,'([0-9a-f]+)'\);", text)
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

