#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

: "${PARTNER_PANEL_DOMAIN:?Set PARTNER_PANEL_DOMAIN in migration.env}"
: "${PARTNER_CERT_EMAIL:?Set PARTNER_CERT_EMAIL in migration.env}"
: "${PARTNER_MYSQL_PASSWORD:?Set PARTNER_MYSQL_PASSWORD in migration.env}"
: "${PARTNER_ADMIN_USERNAME:?Set PARTNER_ADMIN_USERNAME in migration.env}"
: "${PARTNER_ADMIN_PASSWORD_HASH:?Set PARTNER_ADMIN_PASSWORD_HASH in migration.env}"
: "${PARTNER_SUBSCRIPTION_TITLE:?Set PARTNER_SUBSCRIPTION_TITLE in migration.env}"
: "${PARTNER_SUPPORT_TELEGRAM:?Set PARTNER_SUPPORT_TELEGRAM in migration.env}"
: "${PARTNER_BOT_TELEGRAM:?Set PARTNER_BOT_TELEGRAM in migration.env}"

PARTNER_PANEL_UVICORN_PORT="${PARTNER_PANEL_UVICORN_PORT:-8001}"
PARTNER_BOT_SERVER_IP="${PARTNER_BOT_SERVER_IP:-$TARGET_HOST}"
: "${PARTNER_BOT_SERVER_IP:?Set PARTNER_BOT_SERVER_IP or TARGET_HOST in migration.env}"
PARTNER_DATABASE_TYPE="${PARTNER_DATABASE_TYPE:-mysql}"
PARTNER_MARZBAN_VERSION="${PARTNER_MARZBAN_VERSION:-latest}"

SCRIPT_LOCAL_PATH="${PARTNER_INSTALL_SCRIPT_LOCAL_PATH:-$SCRIPT_DIR/../marzban.sh}"
if [[ ! -s "$SCRIPT_LOCAL_PATH" ]]; then
  echo "Local marzban installer script not found: $SCRIPT_LOCAL_PATH" >&2
  exit 2
fi

PANEL_REF="${PANEL_USER}@${PANEL_HOST}"
REMOTE_SCRIPT="/tmp/marzban_partner_install_$$.sh"

echo "Uploading partner installer to ${PANEL_REF}:${REMOTE_SCRIPT}"
upload_utf8_file "$SCRIPT_LOCAL_PATH" "$PANEL_REF" "$REMOTE_SCRIPT"

declare -a install_args=(
  install-partner
  --domain "$PARTNER_PANEL_DOMAIN"
  --cert-email "$PARTNER_CERT_EMAIL"
  --mysql-password "$PARTNER_MYSQL_PASSWORD"
  --admin-username "$PARTNER_ADMIN_USERNAME"
  --admin-password-hash "$PARTNER_ADMIN_PASSWORD_HASH"
  --subscription-title "$PARTNER_SUBSCRIPTION_TITLE"
  --support-telegram "$PARTNER_SUPPORT_TELEGRAM"
  --bot-telegram "$PARTNER_BOT_TELEGRAM"
  --database "$PARTNER_DATABASE_TYPE"
  --version "$PARTNER_MARZBAN_VERSION"
  --uvicorn-port "$PARTNER_PANEL_UVICORN_PORT"
  --bot-server-ip "$PARTNER_BOT_SERVER_IP"
  --non-interactive
)

if [[ "${PARTNER_SKIP_DNS_CHECK:-false}" == "true" ]]; then
  install_args+=(--skip-dns-check)
fi
if [[ "${PARTNER_SKIP_CERT:-false}" == "true" ]]; then
  install_args+=(--skip-cert)
fi
if [[ "${PARTNER_SKIP_FIREWALL:-false}" == "true" ]]; then
  install_args+=(--skip-firewall)
fi
if [[ "${PARTNER_NO_LOGS:-true}" == "true" ]]; then
  install_args+=(--no-logs)
fi

quoted_args=()
for arg in "${install_args[@]}"; do
  quoted_args+=("$(printf '%q' "$arg")")
done
cmd="${quoted_args[*]}"

echo "Running partner panel install on source host"
run_panel_ssh "chmod +x '$REMOTE_SCRIPT' && '$REMOTE_SCRIPT' $cmd"
run_panel_ssh "rm -f '$REMOTE_SCRIPT'"

echo "Verifying partner panel endpoint https://${PARTNER_PANEL_DOMAIN}:${PARTNER_PANEL_UVICORN_PORT}/dashboard/"
status_code="$(run_panel_ssh "curl -k -s -o /dev/null -w '%{http_code}' 'https://${PARTNER_PANEL_DOMAIN}:${PARTNER_PANEL_UVICORN_PORT}/dashboard/'" | tr -d '\r')"
if [[ ! "$status_code" =~ ^[23] ]]; then
  echo "Panel health check failed with HTTP ${status_code}" >&2
  exit 3
fi

echo "Partner panel installation complete and healthy (HTTP ${status_code})."
