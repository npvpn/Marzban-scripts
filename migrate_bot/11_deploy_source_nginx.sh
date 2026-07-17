#!/usr/bin/env bash
set -euo pipefail

# Deploy nginx-only on source host (post-migration).
# Fixes: old default.conf / template still referencing nvb_web.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/common.sh"

SOURCE_REF="${SOURCE_USER}@${SOURCE_HOST}"
REMOTE_BASE="${SOURCE_PATH}"

echo "Uploading nginx config to ${SOURCE_REF}:${REMOTE_BASE}/etc/nginx/conf/default.conf"
upload_utf8_file "$SCRIPT_DIR/nginx-megasecure-source.conf" "$SOURCE_REF" "${REMOTE_BASE}/etc/nginx/conf/default.conf"

echo "Disabling old nginx envsubst template (it overwrites default.conf on start)"
run_ssh "$SOURCE_REF" "cd '${REMOTE_BASE}' && \
  if [ -f etc/nginx/templates/default.conf.template ]; then \
    mv -f etc/nginx/templates/default.conf.template etc/nginx/templates/default.conf.template.bak; \
  fi && \
  ls -la etc/nginx/conf/default.conf etc/nginx/templates/ 2>/dev/null || true"

echo "Uploading docker-compose.nginx-only.yml"
upload_utf8_file "$SCRIPT_DIR/docker-compose.nginx-only.yml" "$SOURCE_REF" "${REMOTE_BASE}/docker-compose.nginx-only.yml"

echo "Restarting nginx-only stack"
run_ssh "$SOURCE_REF" "cd '${REMOTE_BASE}' && \
  docker compose down 2>/dev/null || true && \
  docker compose -f docker-compose.nginx-only.yml up -d && \
  sleep 2 && \
  docker exec nginx_n_nvb nginx -t && \
  docker ps --filter name=nginx_n_nvb --format '{{.Names}} {{.Status}}'"

echo "Smoke test from inside nginx container"
run_ssh "$SOURCE_REF" "docker exec nginx_n_nvb wget -qO- --no-check-certificate 'https://172.17.0.1:8001/dashboard/' | head -5"

echo "Smoke test public /sub/ (first bytes)"
run_ssh "$SOURCE_REF" "curl -skI 'https://app.megasecure.ru/sub/test' | head -5 || true"

echo "Done. If curl still fails, check: docker logs nginx_n_nvb --tail 30"
