#!/usr/bin/env python3
"""Map legacy source .env into current platform + panel settings.

Used by 01 (preview, no writes) and 04 (apply).
"""

from __future__ import annotations

import argparse
import json
import re
import shlex
import sys
from pathlib import Path

_BOT_FILE_PREFIX = re.compile(r"^\d+__")

DEFAULT_SUB_CLIENT_NOTE = (
    "• ID ПОЛЬЗОВАТЕЛЯ: <tg_id> •\n"
    "• ↖️ ССЫЛКА ДЛЯ УПРАВЛЕНИЯ ПОДПИСКОЙ • ССЫЛКА ПОДДЕРЖКИ ↗️  •\n"
    "• Не работает VPN? Нажмите на кнопку 🔁👆 •"
)

DEFAULT_MARZBAN_SUBSCRIPTION = {
    "sub_profile_url": "",
    "sub_profile_title": "",
    "sub_update_interval": "12",
    "sub_client_note": DEFAULT_SUB_CLIENT_NOTE,
    "bs_extra_reset_pool_on_prolong": False,
    "sub_device_limit_hard_mode": False,
    "sub_revoked_announce_text": DEFAULT_SUB_CLIENT_NOTE,
    "sub_expired_announce_text": DEFAULT_SUB_CLIENT_NOTE,
    "sub_device_limit_announce_text": DEFAULT_SUB_CLIENT_NOTE,
    "sub_unsupported_client_announce_text": DEFAULT_SUB_CLIENT_NOTE,
    "sub_bs_limit_announce_text": DEFAULT_SUB_CLIENT_NOTE,
    "sub_revoked_server_text": ["Эта ссылка не активна", "Обновите ссылку в боте"],
    "sub_expired_server_text": ["Подписка истекла", "Продлите подписку в боте"],
    "sub_device_limit_server_text": ["Достигнут лимит устройств", "Удалите старое устройство"],
    "sub_unsupported_client_server_text": ["Это приложение не поддерживается", "Установите другое"],
    "sub_bs_limit_server_text": [],
}

DEFAULT_BOT_SETTINGS = {
    "support_link": "",
    "subscription_domain": "",
    "admin_ids": [],
    "private_mode": False,
    "recaptcha": {"enabled": False},
    "personalize": {
        "service_name": "VPN Service",
        "thumbnail_url": "",
        "thumbnail_image_path": "",
        "keys_left": 3,
        "available_locations": "",
        "show_info": "",
    },
    "trial_params": {
        "change_country_delay": 1,
        "trial_enable": True,
        "paid_trial_enable": False,
        "change_paid_trial": 9,
        "channel_check_enabled": False,
        "channel_username": "",
    },
    "recurring_autopay_policy": {
        "attempts_limit": 4,
        "retry_interval_seconds": 24 * 60 * 60,
        "message_send_limit": 2,
    },
    "marzban_user_defaults": {"limit_gb": None, "reset": None},
    "marzban_subscription": dict(DEFAULT_MARZBAN_SUBSCRIPTION),
    "add_earning_system": {"text_for_button": ""},
    "partner_system": {
        "enabled": False,
        "on_startup": False,
        "first_purchase_percent": 20,
        "repeat_purchase_percent": 10,
    },
    "referral_system": {"enabled": True, "purchase_bonus_mode": "every_purchase"},
    "promo_code_system": {"enabled": False, "full_sub_mode": False},
    "change_tariff_system": {"enabled": True},
    "white_list": {"enabled": False},
    "one_button_for_start": {"enabled": False},
    "display_cheap_tariff": {"enabled": False},
    "device_management": {"enabled": False},
    "sub_page_pay": {"enabled": False},
    "web_frontend": {
        "enabled": False,
        "domain": "",
        "telegram_login_domain": "",
        "favicon_path": "/favicon.svg",
    },
    "tariff_matrix": {"enabled": False},
    "mass_message": {"enabled": False},
    "upload_image_system": {"enabled": True},
    "url_for_app": {"url": "https://onelink.to/46cwxs"},
    "tg_bot": {"use_webapp": False, "hide_commands": True, "languages": ["ru"], "log_errors_to_admin": False},
    "language_block": {"blocked_langs": []},
    "is_service_bot": False,
    "show_ads": True,
    "chatwoot": {"website_token": "", "identity_hmac_secret": "", "admin_base_url": ""},
    "telegraph": {"access_token": ""},
    "welcome_page": {"title": "", "subtitle": "", "feature_1": "", "feature_2": ""},
}

PARTNER_B_VARS = (
    "TARGET_BOT_DOMAIN",
    "PARTNER_PANEL_DOMAIN",
    "PARTNER_CERT_EMAIL",
    "PARTNER_MYSQL_PASSWORD",
    "PARTNER_ADMIN_USERNAME",
    "PARTNER_ADMIN_PASSWORD_HASH",
    "PARTNER_SUBSCRIPTION_TITLE",
    "PARTNER_SUPPORT_TELEGRAM",
    "PARTNER_BOT_TELEGRAM",
    "PARTNER_BOT_SERVER_IP",
)

ALWAYS_VARS = (
    "SOURCE_HOST",
    "SOURCE_USER",
    "SOURCE_PATH",
    "TARGET_HOST",
    "TARGET_USER",
    "TARGET_PATH",
    "SOURCE_BOT_USERNAME",
    "TARGET_BOT_USERNAME",
    "TARGET_BOT_ID",
    "TARGET_SERVER_ID",
    "TARGET_BOT_ADMIN_ID",
)


def parse_env_file(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
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


def load_env_dir(env_dir: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    env.update(parse_env_file(env_dir / ".env"))
    env.update(parse_env_file(env_dir / ".env.marzban"))
    return env


def s(env: dict[str, str], name: str, default: str = "") -> str:
    return str(env.get(name, default) or default)


def b(env: dict[str, str], name: str, default: bool = False) -> bool:
    raw = str(env.get(name, str(default))).strip().lower()
    return raw in {"1", "true", "yes", "on", "y"}


def i(env: dict[str, str], name: str, default: int = 0) -> int:
    try:
        return int(str(env.get(name, default)).strip())
    except Exception:
        return default


def csv_list(raw: str) -> list[str]:
    return [x.strip() for x in raw.replace("\n", ",").split(",") if x.strip()]


def parse_admin_ids(env: dict[str, str]) -> list[int]:
    raw = s(env, "ADMIN_IDS") or s(env, "TG_ADMIN_IDS") or s(env, "ADMINS") or s(env, "SUPER_ADMINS")
    raw = raw.strip().strip("[]")
    ids: list[int] = []
    for part in csv_list(raw):
        part = part.strip().strip("'\"")
        if part.lstrip("-").isdigit():
            ids.append(int(part))
    return ids


def normalize_domain(value: str) -> str:
    raw = (value or "").strip().replace("https://", "").replace("http://", "").strip("/")
    if not raw:
        return ""
    host = raw.split("/")[0]
    return host.strip().lower()


def sql_str(value) -> str:
    if value is None:
        return "NULL"
    return "'" + str(value).replace("'", "''") + "'"


def prefixed_bot_filename(name: str, bot_id: str) -> str:
    name = (name or "").strip()
    if not name:
        return ""
    base = Path(name).name
    base = _BOT_FILE_PREFIX.sub("", base)
    bid = str(bot_id or "").strip()
    if not bid.isdigit():
        return base
    return f"{bid}__{base}"


def default_bot_settings(*, public_name: str = "", subscription_domain: str = "") -> dict:
    data = json.loads(json.dumps(DEFAULT_BOT_SETTINGS))
    title = str(public_name or "").strip()
    if title:
        data["personalize"]["service_name"] = title
        data["marzban_subscription"]["sub_profile_title"] = title
    if subscription_domain:
        data["subscription_domain"] = normalize_domain(subscription_domain)
    return data


def build_mappings(
    env: dict[str, str],
    *,
    target_bot_domain: str = "",
    target_bot_username: str = "",
    target_bot_public_name: str = "",
    target_bot_id: str = "",
) -> dict:
    domain = normalize_domain(target_bot_domain)
    username = (target_bot_username or "").lstrip("@").strip()
    title = (target_bot_public_name or "").strip() or username or "VPN Service"
    admin_ids = parse_admin_ids(env)

    sub_client_note = s(env, "SUB_CLIENT_NOTE", DEFAULT_SUB_CLIENT_NOTE)
    revoked_announce = s(env, "SUB_REVOKED_ANNOUNCE_TEXT", sub_client_note)
    expired_announce = s(env, "SUB_EXPIRED_ANNOUNCE_TEXT", sub_client_note)
    device_announce = s(env, "SUB_DEVICE_LIMIT_ANNOUNCE_TEXT", sub_client_note)
    unsupported_announce = s(env, "SUB_UNSUPPORTED_CLIENT_ANNOUNCE_TEXT", sub_client_note)
    bs_announce = s(env, "SUB_BS_LIMIT_ANNOUNCE_TEXT", sub_client_note)

    revoked_server = csv_list(s(env, "SUB_REVOKED_SERVER_TEXT", "Эта ссылка не активна,Обновите ссылку в боте"))
    expired_server = csv_list(s(env, "SUB_EXPIRED_SERVER_TEXT", "Подписка истекла,Продлите подписку в боте"))
    device_server = csv_list(s(env, "SUB_DEVICE_LIMIT_SERVER_TEXT", "Достигнут лимит устройств,Удалите старое устройство"))
    unsupported_server = csv_list(
        s(env, "SUB_UNSUPPORTED_CLIENT_SERVER_TEXT", "Это приложение не поддерживается,Установите другое")
    )
    bs_server = csv_list(s(env, "SUB_BS_LIMIT_SERVER_TEXT"))

    support_link = s(env, "TG_SUPPORT_LINK", "")
    support_url = s(env, "SUB_SUPPORT_URL", "")
    if not support_url and support_link:
        support_url = support_link if "://" in support_link or support_link.startswith("@") else f"https://t.me/{support_link.lstrip('@')}"
    if not support_url:
        support_url = "https://t.me/"

    bot_url = s(env, "BOT_URL", "")
    if not bot_url and username:
        bot_url = f"https://t.me/{username}"

    pg_data = default_bot_settings(public_name=title, subscription_domain=domain)
    pg_data["support_link"] = support_link
    pg_data["private_mode"] = b(env, "PRIVATE_MODE", False)
    if admin_ids:
        pg_data["admin_ids"] = admin_ids
    pg_data["personalize"] = {
        "service_name": s(env, "SERVICE_NAME", s(env, "BOT_NAME", title)),
        "thumbnail_url": s(env, "THUMBNAIL_URL", ""),
        "thumbnail_image_path": prefixed_bot_filename(s(env, "THUMBNAIL_IMAGE_PATH", ""), target_bot_id),
        "keys_left": i(env, "KEYS_LEFT_NOTIFICATION", 3),
        "available_locations": s(env, "AVAILABLE_LOCATIONS", ""),
        "show_info": s(env, "SHOW_INFO", ""),
    }
    pg_data["trial_params"] = {
        "change_country_delay": i(env, "CHANGE_COUNTRY_DELAY_IN_DAYS", 1),
        "trial_enable": b(env, "FREE_TRIAL_ENABLE", True),
        "paid_trial_enable": b(env, "PAID_TRIAL_ENABLE", False),
        "change_paid_trial": i(env, "CHANGE_PAID_TRIAL", 9),
        "channel_check_enabled": b(env, "TRIAL_CHANNEL_CHECK_ENABLED", False),
        "channel_username": s(env, "TRIAL_CHANNEL_USERNAME", ""),
    }
    pg_data["partner_system"] = {
        "enabled": b(env, "PARTNER_SYSTEM_ENABLED", False),
        "on_startup": b(env, "PARTNER_SYSTEM_ON_STARTUP", False),
        "first_purchase_percent": i(env, "PARTNER_FIRST_PURCHASE_PERCENT", 20),
        "repeat_purchase_percent": i(env, "PARTNER_REPEAT_PURCHASE_PERCENT", 10),
    }
    pg_data["device_management"] = {"enabled": b(env, "DEVICE_MANAGEMENT_ENABLED", False)}
    pg_data["web_frontend"] = {
        "enabled": False,
        "domain": "",
        "telegram_login_domain": "",
        "favicon_path": "/favicon.svg",
    }
    pg_data["marzban_subscription"] = {
        "sub_profile_url": s(env, "SUB_PROFILE_URL", ""),
        "sub_profile_title": s(env, "SUB_PROFILE_TITLE", title),
        "sub_update_interval": str(s(env, "SUB_UPDATE_INTERVAL", "12") or "12"),
        "sub_client_note": sub_client_note,
        "bs_extra_reset_pool_on_prolong": b(env, "BS_EXTRA_RESET_POOL_ON_PROLONG", False),
        "sub_device_limit_hard_mode": b(env, "SUB_DEVICE_LIMIT_HARD_MODE", False),
        "sub_revoked_announce_text": revoked_announce,
        "sub_expired_announce_text": expired_announce,
        "sub_device_limit_announce_text": device_announce,
        "sub_unsupported_client_announce_text": unsupported_announce,
        "sub_bs_limit_announce_text": bs_announce,
        "sub_revoked_server_text": revoked_server,
        "sub_expired_server_text": expired_server,
        "sub_device_limit_server_text": device_server,
        "sub_unsupported_client_server_text": unsupported_server,
        "sub_bs_limit_server_text": bs_server,
    }

    marz = pg_data["marzban_subscription"]
    panel_bot_settings = {
        "sub_update_interval": marz["sub_update_interval"],
        "sub_support_url": support_url,
        "sub_profile_title": marz["sub_profile_title"],
        "sub_client_note": marz["sub_client_note"],
        "sub_profile_url": marz["sub_profile_url"],
        "sub_subscription_domain": domain,
        "bot_url": bot_url,
        "sub_pay_url": "",
        "show_ads": bool(pg_data.get("show_ads", True)),
        "sub_device_limit_hard_mode": marz["sub_device_limit_hard_mode"],
        "bs_extra_reset_pool_on_prolong": marz["bs_extra_reset_pool_on_prolong"],
        "sub_revoked_announce_text": marz["sub_revoked_announce_text"],
        "sub_expired_announce_text": marz["sub_expired_announce_text"],
        "sub_device_limit_announce_text": marz["sub_device_limit_announce_text"],
        "sub_unsupported_client_announce_text": marz["sub_unsupported_client_announce_text"],
        "sub_bs_limit_announce_text": marz["sub_bs_limit_announce_text"],
        "sub_revoked_server_text": marz["sub_revoked_server_text"],
        "sub_expired_server_text": marz["sub_expired_server_text"],
        "sub_device_limit_server_text": marz["sub_device_limit_server_text"],
        "sub_unsupported_client_server_text": marz["sub_unsupported_client_server_text"],
        "sub_bs_limit_server_text": marz["sub_bs_limit_server_text"],
    }

    panel_global = {}
    routing_happ = s(env, "SUB_ROUTING_HAPP", "")
    routing_v2raytun = s(env, "SUB_ROUTING_V2RAYTUN", "")
    if routing_happ:
        panel_global["sub_routing_happ"] = routing_happ
    if routing_v2raytun:
        panel_global["sub_routing_v2raytun"] = routing_v2raytun

    bot_id = str(target_bot_id or "").strip() or "0"
    sql = [
        "BEGIN;",
        f"INSERT INTO bot_payment_settings (bot_id) VALUES ({bot_id}) ON CONFLICT (bot_id) DO NOTHING;",
        (
            "WITH inserted AS (INSERT INTO bot_yookassa_settings "
            "(enable, provider_token, vat_code, external, recurrent, allow_unlink, api_token, shop_id, paycheck_email, timeout_ms) "
            f"VALUES ({str(b(env, 'YOO_KASSA_ENABLE', False)).lower()}, {sql_str(s(env, 'YOO_KASSA_PROVIDER_TOKEN'))}, "
            f"{i(env, 'YOO_KASSA_NDS', 1)}, {str(b(env, 'YOO_KASSA_EXTERNAL', False)).lower()}, "
            f"{str(b(env, 'YOO_KASSA_RECCURENT', False)).lower()}, {str(b(env, 'YOO_KASSA_ALLOW_UNLINK', False)).lower()}, "
            f"{sql_str(s(env, 'YOO_KASSA_API_TOKEN'))}, {i(env, 'YOO_KASSA_SHOP_ID', 0)}, "
            f"{sql_str(s(env, 'EMAIL_PAYCHECK'))}, {i(env, 'YOO_KASSA_TIMEOUT_MS', 15000)}) RETURNING id) "
            f"UPDATE bot_payment_settings SET yookassa_settings_id=(SELECT id FROM inserted) WHERE bot_id={bot_id};"
        ),
        (
            "WITH inserted AS (INSERT INTO bot_aaio_settings "
            "(enable, host, api_key, shop_id, secret_key_one, secret_key_two, secret_key_webhook) "
            f"VALUES ({str(b(env, 'AAIO_ENABLE', False)).lower()}, {sql_str(s(env, 'AAIO_HOST'))}, "
            f"{sql_str(s(env, 'AAIO_API_KEY'))}, {sql_str(s(env, 'AAIO_SHOP_ID'))}, "
            f"{sql_str(s(env, 'AAIO_SECRET_ONE'))}, {sql_str(s(env, 'AAIO_SECRET_TWO'))}, "
            f"{sql_str(s(env, 'AAIO_SECRET_KEY_WEBHOOK'))}) RETURNING id) "
            f"UPDATE bot_payment_settings SET aaio_settings_id=(SELECT id FROM inserted) WHERE bot_id={bot_id};"
        ),
        (
            "WITH inserted AS (INSERT INTO bot_lava_settings (enable, shop_id, secret_key, second_secret_key) "
            f"VALUES ({str(b(env, 'LAVA_ENABLE', False)).lower()}, {sql_str(s(env, 'LAVA_SHOP_ID'))}, "
            f"{sql_str(s(env, 'LAVA_SECRET_KEY'))}, {sql_str(s(env, 'LAVA_SECOND_SECRET_KEY'))}) RETURNING id) "
            f"UPDATE bot_payment_settings SET lava_settings_id=(SELECT id FROM inserted) WHERE bot_id={bot_id};"
        ),
        (
            "WITH inserted AS (INSERT INTO bot_cryptobot_settings (enabled, token) "
            f"VALUES ({str(b(env, 'CRYPTO_ENABLED', False)).lower()}, {sql_str(s(env, 'CRYPTO_BOT_API_TOKEN'))}) RETURNING id) "
            f"UPDATE bot_payment_settings SET cryptobot_settings_id=(SELECT id FROM inserted) WHERE bot_id={bot_id};"
        ),
        (
            "WITH inserted AS (INSERT INTO bot_robokassa_settings "
            "(enable, merchant_login, password_1, password_2, test_password_1, test_password_2, test_mode) "
            f"VALUES ({str(b(env, 'ROBOKASSA_ENABLE', False)).lower()}, {sql_str(s(env, 'ROBOKASSA_MERCHANT_LOGIN'))}, "
            f"{sql_str(s(env, 'ROBOKASSA_PASSWORD_1'))}, {sql_str(s(env, 'ROBOKASSA_PASSWORD_2'))}, "
            f"{sql_str(s(env, 'ROBOKASSA_TEST_PASSWORD_1'))}, {sql_str(s(env, 'ROBOKASSA_TEST_PASSWORD_2'))}, "
            f"{str(b(env, 'ROBOKASSA_TEST_MODE', False)).lower()}) RETURNING id) "
            f"UPDATE bot_payment_settings SET robokassa_settings_id=(SELECT id FROM inserted) WHERE bot_id={bot_id};"
        ),
        (
            "WITH inserted AS (INSERT INTO bot_cryptomus_settings (enabled, merchant_uuid, mode, api_key) "
            f"VALUES ({str(b(env, 'CRYPTOMUS_ENABLED', False)).lower()}, {sql_str(s(env, 'CRYPTOMUS_MERCHANT_UUID'))}, "
            f"{sql_str(s(env, 'CRYPTOMUS_MODE', 'heleket'))}, {sql_str(s(env, 'CRYPTOMUS_API_KEY'))}) RETURNING id) "
            f"UPDATE bot_payment_settings SET cryptomus_settings_id=(SELECT id FROM inserted) WHERE bot_id={bot_id};"
        ),
        (
            "WITH inserted AS (INSERT INTO bot_cryptocloud_settings (enabled, api_key, shop_id, secret) "
            f"VALUES ({str(b(env, 'CCLOUD_ENABLE', False)).lower()}, {sql_str(s(env, 'CCLOUD_API_KEY'))}, "
            f"{sql_str(s(env, 'CCLOUD_SHOP_ID'))}, {sql_str(s(env, 'CCLOUD_SECRET'))}) RETURNING id) "
            f"UPDATE bot_payment_settings SET cryptocloud_settings_id=(SELECT id FROM inserted) WHERE bot_id={bot_id};"
        ),
        "COMMIT;",
    ]

    return {
        "pg_bot_settings": pg_data,
        "panel_bot_settings": panel_bot_settings,
        "panel_global_settings": panel_global,
        "payment_sql": "\n".join(sql) + "\n",
    }


def check_env_completeness(migration_env: dict[str, str]) -> dict:
    missing_always = [name for name in ALWAYS_VARS if not str(migration_env.get(name, "")).strip()]
    domain = str(migration_env.get("TARGET_BOT_DOMAIN", "")).strip()
    partner_domain = str(migration_env.get("PARTNER_PANEL_DOMAIN", "")).strip()
    scenario_b = bool(domain or partner_domain)
    missing_b = []
    if scenario_b:
        missing_b = [name for name in PARTNER_B_VARS if not str(migration_env.get(name, "")).strip()]
        if not str(migration_env.get("TARGET_BOT_API_TOKEN", "")).strip():
            missing_b.append("TARGET_BOT_API_TOKEN")
    warnings = []
    if not scenario_b:
        warnings.append("TARGET_BOT_DOMAIN and PARTNER_PANEL_DOMAIN are empty — scenario B env was not checked")
    return {
        "scenario_b": scenario_b,
        "missing_always": missing_always,
        "missing_scenario_b": missing_b,
        "warnings": warnings,
        "ok": not missing_always and not missing_b,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-dir", default="")
    parser.add_argument("--out-dir", default="")
    parser.add_argument("--target-bot-domain", default="")
    parser.add_argument("--target-bot-username", default="")
    parser.add_argument("--target-bot-public-name", default="")
    parser.add_argument("--target-bot-id", default="")
    parser.add_argument("--defaults-only", action="store_true")
    parser.add_argument("--check-migration-env", default="")
    args = parser.parse_args()

    if args.defaults_only:
        data = default_bot_settings(
            public_name=args.target_bot_public_name,
            subscription_domain=args.target_bot_domain,
        )
        json.dump(data, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
        return 0

    if args.check_migration_env:
        env = parse_env_file(Path(args.check_migration_env))
        result = check_env_completeness(env)
        if args.out_dir:
            Path(args.out_dir).mkdir(parents=True, exist_ok=True)
            Path(args.out_dir, "env_completeness.json").write_text(
                json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
            )
        json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
        return 0 if result["ok"] else 1

    env_dir = Path(args.env_dir)
    env = load_env_dir(env_dir)
    mapped = build_mappings(
        env,
        target_bot_domain=args.target_bot_domain,
        target_bot_username=args.target_bot_username,
        target_bot_public_name=args.target_bot_public_name,
        target_bot_id=args.target_bot_id,
    )
    if args.out_dir:
        out = Path(args.out_dir)
        out.mkdir(parents=True, exist_ok=True)
        (out / "bot_settings_patch.json").write_text(
            json.dumps(mapped["pg_bot_settings"], ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        (out / "panel_bot_settings.json").write_text(
            json.dumps(mapped["panel_bot_settings"], ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        (out / "panel_global_settings.json").write_text(
            json.dumps(mapped["panel_global_settings"], ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        (out / "payment_settings.sql").write_text(mapped["payment_sql"], encoding="utf-8")
    else:
        json.dump(mapped, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
