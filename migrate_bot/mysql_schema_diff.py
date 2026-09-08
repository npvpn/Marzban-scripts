#!/usr/bin/env python3
"""Compare legacy MySQL columns with the current npvpn panel fork schema."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Expected dest columns for current panel (v2026.08.x). Used when partner
# fork is not installed yet (dry-run before step 08).
FORK_EXPECTED_COLUMNS: dict[str, list[str]] = {
    "users": [
        "id",
        "username",
        "status",
        "used_traffic",
        "data_limit",
        "data_limit_reset_strategy",
        "expire",
        "admin_id",
        "sub_revoked_at",
        "sub_updated_at",
        "sub_last_user_agent",
        "created_at",
        "note",
        "online_at",
        "on_hold_expire_duration",
        "on_hold_timeout",
        "auto_delete_in_days",
        "edit_at",
        "last_status_change",
        "subscription_token",
        "bot_id",
        "device_limit",
        "bs_extra",
        "bs_extra_period",
    ],
    "proxies": ["id", "user_id", "type", "settings"],
    "hosts": [
        "id",
        "remark",
        "address",
        "port",
        "path",
        "sni",
        "host",
        "alpn",
        "fingerprint",
        "inbound_tag",
        "security",
        "allowinsecure",
        "is_disabled",
        "mux_enable",
        "fragment_setting",
        "noise_setting",
        "random_user_agent",
        "use_sni_as_host",
        "xhttp_extra",
        "order",
    ],
    "inbounds": ["id", "tag"],
    "jwt": ["id", "secret_key"],
    "tls": ["id", "key", "certificate"],
    "user_devices": [
        "id",
        "user_id",
        "hwid",
        "device_os",
        "ver_os",
        "device_model",
        "user_agent",
        "status",
        "first_seen",
        "last_seen",
    ],
    "next_plans": ["id", "user_id", "data_limit", "expire", "add_remaining_traffic", "fire_on_either"],
    "user_usage_logs": ["id", "user_id", "used_traffic_at_reset", "reset_at"],
    "nodes": [
        "id",
        "name",
        "address",
        "port",
        "api_port",
        "xray_version",
        "status",
        "last_status_change",
        "message",
        "created_at",
        "uplink",
        "downlink",
        "usage_coefficient",
    ],
}

REQUIRED_COPY = {
    "users": ["username"],
    "proxies": ["user_id", "type"],
    "jwt": ["secret_key"],
}


def diff_table(source: list[str], dest: list[str]) -> dict:
    src_set = list(dict.fromkeys(source))
    dest_set = list(dict.fromkeys(dest))
    src_names = set(src_set)
    dest_names = set(dest_set)
    return {
        "will_copy": [c for c in src_set if c in dest_names],
        "dest_only_default": [c for c in dest_set if c not in src_names],
        "source_only_dropped": [c for c in src_set if c not in dest_names],
    }


def build_report(source_cols: dict[str, list[str]], dest_cols: dict[str, list[str]]) -> dict:
    blockers: list[str] = []
    tables = {}
    for table, src in sorted(source_cols.items()):
        dest = dest_cols.get(table) or FORK_EXPECTED_COLUMNS.get(table) or []
        if not dest:
            tables[table] = {
                "will_copy": src,
                "dest_only_default": [],
                "source_only_dropped": [],
                "note": "dest schema unknown; dump will keep source columns if dest table exists",
            }
            continue
        info = diff_table(src, dest)
        tables[table] = info
        for required in REQUIRED_COPY.get(table, []):
            if required not in info["will_copy"]:
                blockers.append(f"{table}.{required} missing on source — cannot import")
        if table in dest_cols or table in FORK_EXPECTED_COLUMNS:
            if not info["will_copy"]:
                blockers.append(f"{table}: no overlapping columns with fork schema")
    return {
        "ok": not blockers,
        "blockers": blockers,
        "tables": tables,
        "dest_source": "live" if dest_cols else "expected_fork",
    }


def load_cols(path: str) -> dict[str, list[str]]:
    if not path:
        return {}
    p = Path(path)
    if not p.is_file():
        return {}
    raw = json.loads(p.read_text(encoding="utf-8"))
    return {str(k): [str(x) for x in v] for k, v in raw.items()}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-columns-json", required=True)
    parser.add_argument("--dest-columns-json", default="")
    parser.add_argument("--out", default="")
    args = parser.parse_args()
    report = build_report(load_cols(args.source_columns_json), load_cols(args.dest_columns_json))
    text = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.out:
        Path(args.out).write_text(text, encoding="utf-8")
    sys.stdout.write(text)
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
