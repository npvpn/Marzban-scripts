#!/usr/bin/env python3
"""Transform partner-panel dump into INSERT SQL for a live shared panel.

Keep vless/vmess UUIDs (proxies.settings). Do not copy exclude_inbounds, hosts,
inbounds, nodes, jwt rows, or host_bot_association. Empty host associations stay
"all bots"; existing allowlists stay on the bots already listed.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

# Keep in sync with panel/app/models/bot.py BotSettingsPayload.
BOT_SETTINGS_ALLOWLIST = (
    "sub_update_interval",
    "sub_support_url",
    "sub_profile_title",
    "sub_client_note",
    "sub_profile_url",
    "sub_subscription_domain",
    "bot_url",
    "web_url",
    "sub_revoked_announce_text",
    "sub_expired_announce_text",
    "sub_device_limit_announce_text",
    "sub_device_limit_hard_mode",
    "bs_extra_reset_pool_on_prolong",
    "sub_unsupported_client_announce_text",
    "sub_revoked_server_text",
    "sub_expired_server_text",
    "sub_device_limit_server_text",
    "sub_unsupported_client_server_text",
    "sub_bs_limit_server_text",
    "sub_bs_limit_announce_text",
    "show_ads",
)

# Keep in sync with panel/app/models/settings.py PANEL_SETTING_KEYS.
PANEL_SETTING_KEYS = (
    "sub_custom_headers",
    "bs_monthly_limit",
    "sub_routing_happ",
    "sub_routing_v2raytun",
    "sub_v2ray_json_template",
    "sub_routing_json_default",
    "sub_routing_json_bs",
)

# Cutover onto the shared panel: subscription URLs must not stay on the old domain.
FORCE_CLEAR_SETTINGS_KEYS = ("sub_subscription_domain",)

SERVER_TEXT_KEYS = {
    "sub_revoked_server_text",
    "sub_expired_server_text",
    "sub_device_limit_server_text",
    "sub_unsupported_client_server_text",
    "sub_bs_limit_server_text",
}

USER_TRANSFER_COLUMNS = (
    "username",
    "status",
    "used_traffic",
    "data_limit",
    "data_limit_reset_strategy",
    "expire",
    "sub_revoked_at",
    "sub_updated_at",
    "sub_last_user_agent",
    "subscription_token",
    "created_at",
    "note",
    "online_at",
    "on_hold_expire_duration",
    "on_hold_timeout",
    "device_limit",
    "bs_extra",
    "bs_extra_period",
    "auto_delete_in_days",
    "edit_at",
    "last_status_change",
)

USER_NOT_NULL_DEFAULTS = {
    "status": "active",
    "used_traffic": 0,
    "data_limit_reset_strategy": "no_reset",
}

NEXT_PLAN_COLUMNS = (
    "data_limit",
    "expire",
    "add_remaining_traffic",
    "fire_on_either",
)

DEVICE_COLUMNS = (
    "hwid",
    "device_os",
    "ver_os",
    "device_model",
    "user_agent",
    "status",
    "first_seen",
    "last_seen",
)


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.is_file() or path.stat().st_size == 0:
        return []
    rows = []
    for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError as exc:
            raise SystemExit(f"Invalid JSONL at {path}:{line_no}: {exc}") from exc
    return rows


def read_json_file(path: Path) -> Any:
    if not path.is_file() or path.stat().st_size == 0:
        return None
    text = path.read_text(encoding="utf-8").strip()
    if not text:
        return None
    return json.loads(text)


def read_lines(path: Path) -> list[str]:
    if not path.is_file():
        return []
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def sql_str(value: str) -> str:
    return "'" + value.replace("\\", "\\\\").replace("'", "''") + "'"


def sql_literal(value: Any) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if isinstance(value, float) and value.is_integer():
            return str(int(value))
        return str(value)
    if isinstance(value, (dict, list)):
        return "CAST(" + sql_str(json.dumps(value, ensure_ascii=False)) + " AS JSON)"
    return sql_str(str(value))


def normalize_server_text(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item).strip()]
    if isinstance(value, str):
        return [item.strip() for item in value.split(",") if item.strip()]
    return []


def parse_settings(raw: Any) -> dict[str, Any]:
    if raw is None:
        return {}
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        text = raw.strip()
        if not text:
            return {}
        parsed = json.loads(text)
        if isinstance(parsed, dict):
            return parsed
    return {}


def filter_bot_settings(raw: Any) -> tuple[dict[str, Any], list[str]]:
    payload = parse_settings(raw) if not isinstance(raw, dict) else dict(raw)
    dropped: list[str] = []
    filtered: dict[str, Any] = {}
    allow = set(BOT_SETTINGS_ALLOWLIST)
    panel_keys = set(PANEL_SETTING_KEYS)
    force_clear = set(FORCE_CLEAR_SETTINGS_KEYS)

    for key, value in payload.items():
        if key in panel_keys or key not in allow or key in force_clear:
            dropped.append(key)
            continue
        if value is None:
            continue
        if key in SERVER_TEXT_KEYS:
            normalized = normalize_server_text(value)
            if not normalized:
                continue
            filtered[key] = normalized
            continue
        filtered[key] = value

    for key in force_clear:
        if key in payload:
            dropped.append(key)

    return filtered, sorted(set(dropped))


def load_existing_by_username(rows: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    existing = {}
    for row in rows:
        username = str(row.get("username") or "").strip()
        if not username:
            continue
        existing[username.casefold()] = row
    return existing


def build_report_and_sql(args: argparse.Namespace) -> tuple[str, dict[str, Any], dict[str, Any]]:
    source_users = read_jsonl(args.source_users)
    source_proxies = read_jsonl(args.source_proxies)
    source_next_plans = read_jsonl(args.source_next_plans)
    source_devices = read_jsonl(args.source_devices)
    dest_existing = load_existing_by_username(read_jsonl(args.dest_existing))
    dest_user_columns = set(read_lines(args.dest_user_columns))
    dest_next_plan_columns = set(read_lines(args.dest_next_plan_columns))
    dest_device_columns = set(read_lines(args.dest_device_columns))
    dest_proxy_types = {item.casefold() for item in read_lines(args.dest_proxy_types)}
    dest_inbound_tags = read_lines(args.dest_inbound_tags)
    raw_settings = read_json_file(args.source_bot_settings)
    filtered_settings, dropped_settings = filter_bot_settings(raw_settings)

    user_cols = [col for col in USER_TRANSFER_COLUMNS if col in dest_user_columns]
    next_cols = [col for col in NEXT_PLAN_COLUMNS if col in dest_next_plan_columns]
    device_cols = [col for col in DEVICE_COLUMNS if col in dest_device_columns]

    collisions: list[dict[str, Any]] = []
    skipped: list[str] = []
    to_insert: list[dict[str, Any]] = []

    for user in source_users:
        username = str(user.get("username") or "").strip()
        if not username:
            continue
        match = dest_existing.get(username.casefold())
        if not match:
            to_insert.append(user)
            continue
        bot_username = (match.get("bot_username") or "") or ""
        if bot_username == args.target_bot_username:
            skipped.append(username)
            continue
        collisions.append(
            {
                "username": username,
                "dest_bot_id": match.get("bot_id"),
                "dest_bot_username": bot_username or None,
            }
        )

    if collisions:
        return "", {
            "ok": False,
            "reason": "username_collisions",
            "collisions": collisions,
            "collision_count": len(collisions),
        }, filtered_settings

    proxies_by_user: dict[int, list[dict[str, Any]]] = {}
    unknown_protocols: list[str] = []
    for proxy in source_proxies:
        user_id = proxy.get("user_id")
        if user_id is None:
            continue
        proxy_type = str(proxy.get("type") or "").strip()
        if dest_proxy_types and proxy_type.casefold() not in dest_proxy_types:
            unknown_protocols.append(proxy_type)
        proxies_by_user.setdefault(int(user_id), []).append(proxy)

    next_by_user: dict[int, dict[str, Any]] = {}
    for plan in source_next_plans:
        user_id = plan.get("user_id")
        if user_id is None:
            continue
        next_by_user[int(user_id)] = plan

    devices_by_user: dict[int, list[dict[str, Any]]] = {}
    for device in source_devices:
        user_id = device.get("user_id")
        if user_id is None:
            continue
        devices_by_user.setdefault(int(user_id), []).append(device)

    insert_usernames = {str(user.get("username") or "") for user in to_insert}
    users_without_proxy = [
        str(user.get("username"))
        for user in to_insert
        if not proxies_by_user.get(int(user["id"]), [])
    ]

    lines: list[str] = []
    bot_sql = sql_str(args.target_bot_username)
    settings_sql = sql_literal(filtered_settings)

    lines.append("START TRANSACTION;")
    lines.append(
        "INSERT INTO bots (username, title, created_at, updated_at) "
        f"VALUES ({bot_sql}, {bot_sql}, NOW(), NOW()) "
        "ON DUPLICATE KEY UPDATE title=VALUES(title), updated_at=NOW();"
    )
    lines.append(f"SET @bot_id := (SELECT id FROM bots WHERE username={bot_sql} LIMIT 1);")
    lines.append(
        "INSERT INTO bot_settings (bot_id, data, created_at, updated_at) "
        f"SELECT @bot_id, {settings_sql}, NOW(), NOW() "
        "WHERE NOT EXISTS (SELECT 1 FROM bot_settings WHERE bot_id=@bot_id);"
    )
    lines.append(
        "UPDATE bot_settings SET data="
        f"{settings_sql}, updated_at=NOW() WHERE bot_id=@bot_id;"
    )

    if to_insert:
        col_sql = ", ".join(f"`{col}`" for col in user_cols)
        lines.append(
            "INSERT INTO users ("
            f"{col_sql}{', ' if user_cols else ''}`bot_id`, `admin_id`) VALUES"
        )
        value_rows = []
        for user in to_insert:
            values = []
            for col in user_cols:
                value = user.get(col)
                if value is None and col in USER_NOT_NULL_DEFAULTS:
                    value = USER_NOT_NULL_DEFAULTS[col]
                values.append(sql_literal(value))
            values.extend(["@bot_id", "NULL"])
            value_rows.append("  (" + ", ".join(values) + ")")
        lines.append(",\n".join(value_rows) + ";")

        proxy_values = []
        for user in to_insert:
            username = str(user.get("username") or "")
            for proxy in proxies_by_user.get(int(user["id"]), []):
                settings = parse_settings(proxy.get("settings"))
                proxy_type = str(proxy.get("type") or "")
                proxy_values.append(
                    "  ("
                    + ", ".join(
                        [
                            sql_str(username),
                            sql_literal(proxy_type),
                            sql_literal(settings),
                        ]
                    )
                    + ")"
                )
        if proxy_values:
            lines.append(
                "CREATE TEMPORARY TABLE st_merge_proxies("
                "username varchar(255) not null, type varchar(32) not null, settings json not null);"
            )
            lines.append("INSERT INTO st_merge_proxies (username, type, settings) VALUES")
            lines.append(",\n".join(proxy_values) + ";")
            lines.append(
                "INSERT INTO proxies (`user_id`, `type`, `settings`) "
                "SELECT u.id, p.type, p.settings "
                "FROM st_merge_proxies p "
                "JOIN users u ON u.username = p.username AND u.bot_id = @bot_id;"
            )

        if next_cols:
            plan_values = []
            for user in to_insert:
                plan = next_by_user.get(int(user["id"]))
                if not plan:
                    continue
                username = str(user.get("username") or "")
                values = [sql_str(username)]
                values.extend(sql_literal(plan.get(col)) for col in next_cols)
                plan_values.append("  (" + ", ".join(values) + ")")
            if plan_values:
                col_defs = ", ".join(f"`{col}` varchar(255)" for col in next_cols)
                lines.append("CREATE TEMPORARY TABLE st_merge_plans(username varchar(255) not null, " + col_defs + ");")
                lines.append(
                    "INSERT INTO st_merge_plans (username, "
                    + ", ".join(f"`{col}`" for col in next_cols)
                    + ") VALUES"
                )
                lines.append(",\n".join(plan_values) + ";")
                lines.append(
                    "INSERT INTO next_plans (`user_id`, "
                    + ", ".join(f"`{col}`" for col in next_cols)
                    + ") SELECT u.id, "
                    + ", ".join(f"p.`{col}`" for col in next_cols)
                    + " FROM st_merge_plans p "
                    "JOIN users u ON u.username = p.username AND u.bot_id = @bot_id;"
                )

        if device_cols:
            device_values = []
            for user in to_insert:
                username = str(user.get("username") or "")
                for device in devices_by_user.get(int(user["id"]), []):
                    values = [sql_str(username)]
                    values.extend(sql_literal(device.get(col)) for col in device_cols)
                    device_values.append("  (" + ", ".join(values) + ")")
            if device_values:
                col_defs = ", ".join(f"`{col}` varchar(512)" for col in device_cols)
                lines.append(
                    "CREATE TEMPORARY TABLE st_merge_devices(username varchar(255) not null, "
                    + col_defs
                    + ");"
                )
                lines.append(
                    "INSERT INTO st_merge_devices (username, "
                    + ", ".join(f"`{col}`" for col in device_cols)
                    + ") VALUES"
                )
                lines.append(",\n".join(device_values) + ";")
                lines.append(
                    "INSERT IGNORE INTO user_devices (`user_id`, "
                    + ", ".join(f"`{col}`" for col in device_cols)
                    + ") SELECT u.id, "
                    + ", ".join(f"p.`{col}`" for col in device_cols)
                    + " FROM st_merge_devices p "
                    "JOIN users u ON u.username = p.username AND u.bot_id = @bot_id;"
                )

    lines.append("COMMIT;")
    lines.append("SELECT 'panel_bot_id' AS metric, @bot_id AS value;")
    lines.append(
        "SELECT 'users_for_bot' AS metric, COUNT(*) AS value "
        "FROM users WHERE bot_id=@bot_id;"
    )
    lines.append(
        "SELECT 'proxies_for_bot' AS metric, COUNT(*) AS value "
        "FROM proxies p JOIN users u ON u.id=p.user_id WHERE u.bot_id=@bot_id;"
    )

    report = {
        "ok": True,
        "source_users": len(source_users),
        "insert_users": len(to_insert),
        "skipped_already_on_bot": skipped,
        "skipped_count": len(skipped),
        "users_without_proxy": users_without_proxy,
        "dropped_bot_settings_keys": dropped_settings,
        "kept_bot_settings_keys": sorted(filtered_settings),
        "unknown_proxy_protocols": sorted(set(unknown_protocols)),
        "dest_inbound_tag_count": len(dest_inbound_tags),
        "dest_proxy_types": sorted(dest_proxy_types),
        "user_columns": user_cols,
    }
    return "\n".join(lines) + "\n", report, filtered_settings


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build shared-panel merge SQL from partner dump")
    parser.add_argument("--target-bot-username", required=True)
    parser.add_argument("--source-users", type=Path, required=True)
    parser.add_argument("--source-proxies", type=Path, required=True)
    parser.add_argument("--source-next-plans", type=Path, required=True)
    parser.add_argument("--source-devices", type=Path, required=True)
    parser.add_argument("--source-bot-settings", type=Path, required=True)
    parser.add_argument("--dest-existing", type=Path, required=True)
    parser.add_argument("--dest-user-columns", type=Path, required=True)
    parser.add_argument("--dest-next-plan-columns", type=Path, required=True)
    parser.add_argument("--dest-device-columns", type=Path, required=True)
    parser.add_argument("--dest-proxy-types", type=Path, required=True)
    parser.add_argument("--dest-inbound-tags", type=Path, required=True)
    parser.add_argument("--out-sql", type=Path, required=True)
    parser.add_argument("--out-report", type=Path, required=True)
    parser.add_argument("--out-settings", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    sql, report, settings = build_report_and_sql(args)
    args.out_report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    args.out_settings.write_text(json.dumps(settings, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if not report.get("ok"):
        args.out_sql.write_text("", encoding="utf-8")
        print(f"Username collisions: {report.get('collision_count')}", file=sys.stderr)
        return 4
    args.out_sql.write_text(sql, encoding="utf-8")
    print(
        "Prepared merge: "
        f"insert={report['insert_users']} skip={report['skipped_count']} "
        f"source={report['source_users']}"
    )
    if report["unknown_proxy_protocols"]:
        print(
            "Warning: proxy protocols not seen on destination: "
            + ", ".join(report["unknown_proxy_protocols"]),
            file=sys.stderr,
        )
    if report["dropped_bot_settings_keys"]:
        print(
            "Dropped bot_settings keys: " + ", ".join(report["dropped_bot_settings_keys"]),
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
