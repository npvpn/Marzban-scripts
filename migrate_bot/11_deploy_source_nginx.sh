#!/usr/bin/env bash
set -euo pipefail

# Deploy nginx on the source host: :443 → partner panel :8001
# so https://<domain>/sub/<token> works without the port.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

SOURCE_REF="${SOURCE_USER}@${SOURCE_HOST}"
REMOTE_BASE="${SOURCE_PATH}"

normalize_nginx_host() {
  local raw="$1"
  raw="${raw#https://}"
  raw="${raw#http://}"
  raw="${raw%%/*}"
  raw="${raw%%:*}"
  raw="${raw#,}"
  raw="${raw%,}"
  printf '%s' "$raw"
}

NGINX_DOMAIN="$(normalize_nginx_host "${NGINX_DOMAIN:-${PARTNER_PANEL_DOMAIN:-${TARGET_BOT_DOMAIN:-}}}")"
PANEL_PORT="${PARTNER_PANEL_UVICORN_PORT:-8001}"
LE_CERT="/etc/letsencrypt/live/${NGINX_DOMAIN}/fullchain.pem"
LE_KEY="/etc/letsencrypt/live/${NGINX_DOMAIN}/privkey.pem"
NGINX_EXTRA_DOMAINS="${NGINX_EXTRA_DOMAINS:-}"

nginx_all_hosts=()
if [[ -n "$NGINX_DOMAIN" ]]; then
  nginx_all_hosts+=("$NGINX_DOMAIN")
fi
IFS=',' read -r -a _nginx_extras <<< "$NGINX_EXTRA_DOMAINS"
for extra in "${_nginx_extras[@]}"; do
  extra="$(normalize_nginx_host "$extra")"
  if [[ -z "$extra" || "$extra" == "$NGINX_DOMAIN" ]]; then
    continue
  fi
  skip=0
  for existing in "${nginx_all_hosts[@]}"; do
    if [[ "$existing" == "$extra" ]]; then
      skip=1
      break
    fi
  done
  if [[ "$skip" -eq 0 ]]; then
    nginx_all_hosts+=("$extra")
  fi
done
NGINX_SERVER_NAMES="${nginx_all_hosts[*]}"

if [[ -z "$NGINX_DOMAIN" ]]; then
  echo "Set PARTNER_PANEL_DOMAIN or TARGET_BOT_DOMAIN (or NGINX_DOMAIN) in migration.env" >&2
  exit 2
fi

TEMPLATE="$SCRIPT_DIR/nginx-partner-source.conf.tmpl"
if [[ ! -s "$TEMPLATE" ]]; then
  echo "Missing nginx template: $TEMPLATE" >&2
  exit 2
fi

echo "Deploying source nginx ${NGINX_SERVER_NAMES} :443 → 127.0.0.1:${PANEL_PORT}"

echo "Checking Let's Encrypt certs on source"
if [[ "$(run_ssh "$SOURCE_REF" "if [ -f '$LE_CERT' ] && [ -f '$LE_KEY' ]; then echo ok; else echo missing; fi" | tr -d '\r' | awk 'NF{print; exit}')" != "ok" ]]; then
  echo "Missing $LE_CERT or $LE_KEY on source. Issue/renew certs (step 08 certbot) first." >&2
  exit 3
fi

TMP_CONF="$(mktemp)"
sed \
  -e "s/__SERVER_NAME__/${NGINX_SERVER_NAMES}/g" \
  -e "s/__PANEL_PORT__/${PANEL_PORT}/g" \
  -e "s|__SSL_CERT__|/etc/letsencrypt/live/${NGINX_DOMAIN}/fullchain.pem|g" \
  -e "s|__SSL_KEY__|/etc/letsencrypt/live/${NGINX_DOMAIN}/privkey.pem|g" \
  -e "s/__SSL_SNI__/${NGINX_DOMAIN}/g" \
  "$TEMPLATE" > "$TMP_CONF"

echo "Preparing remote nginx dirs under ${REMOTE_BASE}"
run_ssh "$SOURCE_REF" "mkdir -p '${REMOTE_BASE}/etc/nginx/conf' '${REMOTE_BASE}/certbot/data/.well-known/acme-challenge' '${REMOTE_BASE}/var/log/nginx' '${REMOTE_BASE}/volumes/templates'"

echo "Uploading nginx config"
upload_utf8_file "$TMP_CONF" "$SOURCE_REF" "${REMOTE_BASE}/etc/nginx/conf/default.conf"
rm -f "$TMP_CONF"

echo "Disabling old nginx envsubst template (it overwrites default.conf on start)"
run_ssh "$SOURCE_REF" "cd '${REMOTE_BASE}' && \
  if [ -f etc/nginx/templates/default.conf.template ]; then \
    mv -f etc/nginx/templates/default.conf.template etc/nginx/templates/default.conf.template.bak; \
  fi"

echo "Uploading docker-compose.nginx-only.yml"
upload_utf8_file "$SCRIPT_DIR/docker-compose.nginx-only.yml" "$SOURCE_REF" "${REMOTE_BASE}/docker-compose.nginx-only.yml"

echo "Ensuring stub error pages exist"
run_ssh "$SOURCE_REF" "cd '${REMOTE_BASE}' && \
  if [ ! -s volumes/templates/404.html ]; then printf '<h1>404</h1>\\n' > volumes/templates/404.html; fi && \
  if [ ! -s volumes/templates/50x.html ]; then printf '<h1>50x</h1>\\n' > volumes/templates/50x.html; fi"

echo "Starting or reloading partner-nginx (does not docker compose down the old bot stack)"
run_ssh "$SOURCE_REF" "
  if docker ps --format '{{.Names}}' | grep -qx nginx_n_nvb; then
    docker exec nginx_n_nvb nginx -t && docker exec nginx_n_nvb nginx -s reload
  else
    docker stop nginx_n_nvb 2>/dev/null || true
    docker rm nginx_n_nvb 2>/dev/null || true
    cd '${REMOTE_BASE}' && docker compose -p partner-nginx -f docker-compose.nginx-only.yml up -d
    sleep 2
    docker exec nginx_n_nvb nginx -t
  fi
  docker ps --filter name=nginx_n_nvb --format '{{.Names}} {{.Status}} {{.Ports}}'
"

HOOK_REMOTE="/etc/letsencrypt/renewal-hooks/deploy/reload-partner-nginx.sh"
echo "Installing certbot deploy hook (reload nginx after renew)"
run_ssh "$SOURCE_REF" "mkdir -p /etc/letsencrypt/renewal-hooks/deploy && cat > '$HOOK_REMOTE' <<'EOF'
#!/bin/bash
docker exec nginx_n_nvb nginx -s reload 2>/dev/null || true
EOF
chmod 755 '$HOOK_REMOTE'"

RENEWAL_CONF="/etc/letsencrypt/renewal/${NGINX_DOMAIN}.conf"
echo "Switching certbot renew to webroot (standalone cannot bind :80 while nginx is up)"
run_ssh "$SOURCE_REF" "
  if [ -f '$RENEWAL_CONF' ]; then
    sed -i 's/^authenticator = .*/authenticator = webroot/' '$RENEWAL_CONF'
    if grep -q '^webroot_path' '$RENEWAL_CONF'; then
      sed -i 's|^webroot_path = .*|webroot_path = ${REMOTE_BASE}/certbot/data|' '$RENEWAL_CONF'
    else
      printf '\\nwebroot_path = ${REMOTE_BASE}/certbot/data\\n' >> '$RENEWAL_CONF'
    fi
    if grep -q '^[[]webroot_map[]]' '$RENEWAL_CONF'; then
      true
    else
      printf '\\n[webroot_map]\\n%s = ${REMOTE_BASE}/certbot/data\\n' '${NGINX_DOMAIN}' >> '$RENEWAL_CONF'
    fi
  else
    echo 'No certbot renewal file at $RENEWAL_CONF (ok if certs are managed elsewhere)'
  fi
"

if [[ ${#nginx_all_hosts[@]} -gt 1 && "${SKIP_CERT_EXPAND:-false}" != "true" ]]; then
  certbot_remote="certbot certonly --webroot -w '${REMOTE_BASE}/certbot/data' --expand --non-interactive --agree-tos --cert-name '${NGINX_DOMAIN}'"
  if [[ -n "${PARTNER_CERT_EMAIL:-}" ]]; then
    certbot_remote+=" --email '${PARTNER_CERT_EMAIL}'"
  fi
  for host in "${nginx_all_hosts[@]}"; do
    certbot_remote+=" -d '${host}'"
  done
  echo "Expanding Let's Encrypt cert ${NGINX_DOMAIN} to: ${NGINX_SERVER_NAMES}"
  echo "A-record for extra hosts must point at ${SOURCE_HOST} (HTTP-01 via nginx webroot)."
  run_ssh "$SOURCE_REF" "$certbot_remote"
  run_ssh "$SOURCE_REF" "docker exec nginx_n_nvb nginx -s reload"
fi

echo "Smoke test panel on :${PANEL_PORT}"
run_ssh "$SOURCE_REF" "curl -skI -o /dev/null -w 'panel_%{http_code}\\n' 'https://127.0.0.1:${PANEL_PORT}/dashboard/' || true"

for host in "${nginx_all_hosts[@]}"; do
  echo "Smoke test public https://${host}/dashboard/ and /sub/"
  run_ssh "$SOURCE_REF" "curl -skI -o /dev/null -w '${host}_dash_%{http_code}\\n' 'https://${host}/dashboard/' || true"
  run_ssh "$SOURCE_REF" "curl -skI -o /dev/null -w '${host}_sub_%{http_code}\\n' 'https://${host}/sub/test' || true"
done

echo "Done. Subscriptions: https://${NGINX_DOMAIN}/sub/<token>"
echo "Panel without port: https://${NGINX_DOMAIN}/dashboard/"
if [[ ${#nginx_all_hosts[@]} -gt 1 ]]; then
  echo "Also serving: ${NGINX_SERVER_NAMES}"
fi
echo "Direct panel still: https://${NGINX_DOMAIN}:${PANEL_PORT}/dashboard/"
echo "If curl fails, check: docker logs nginx_n_nvb --tail 50"
