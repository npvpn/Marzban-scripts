#!/usr/bin/env bash
set -eo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
MARZBAN_SCRIPT_SOURCE_ONLY=1 source "$ROOT/marzban.sh"

get_server_public_ip() { echo "203.0.113.10"; }

SSL_DOMAIN="panel.example.com"
SSL_UVICORN_PORT="8001"
out="$(print_install_access false)"
grep -q "https://panel.example.com:8001/dashboard/#/login" <<<"$out"
grep -q "No panel administrator was created." <<<"$out"
grep -q "marzban cli admin create" <<<"$out"
grep -q "did not pass --admin-username" <<<"$out"
grep -q "Is sudo" <<<"$out"

out="$(print_install_access true partneradmin 's3cret')"
grep -q "https://panel.example.com:8001/dashboard/#/login" <<<"$out"
grep -q "partneradmin" <<<"$out"
grep -q "s3cret" <<<"$out"
if grep -q "marzban cli admin create" <<<"$out"; then
    echo "created admin must not ask to create one" >&2
    exit 1
fi

SSL_DOMAIN=""
out="$(print_install_access false)"
grep -q "http://203.0.113.10:8000/dashboard/#/login" <<<"$out"

python3 - <<'PY'
from pathlib import Path
text = Path("marzban.sh").read_text()

def body(name, nxt):
    start = text.index(f"{name}() {{")
    end = text.index(f"{nxt}() {{", start)
    return text[start:end]

install = body("install_command", "install_yq")
partner = body("install_partner_command", "require_ssl_install_params")
up = body("up_marzban", "follow_marzban_logs")
checklist = body("print_post_install_checklist", "partner_runner_label_from_bot")
for label, chunk in (("install", install), ("partner", partner)):
    if "follow_marzban_logs" in chunk:
        raise SystemExit(f"{label} still follows logs")
if "up -d --remove-orphans" not in up:
    raise SystemExit("up_marzban lost detached start")
if "--admin-username" not in install or "--admin-password" not in install:
    raise SystemExit("install is missing admin flags")
if "does not print it" not in checklist:
    raise SystemExit("partner checklist does not explain the password")
if "print_install_access true" not in install:
    raise SystemExit("install does not print created admin credentials")
print("install paths ok")
PY
