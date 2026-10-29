#!/usr/bin/env bash
# Wait for Keycloak, Redis, and IAM so Staff UI /api/login can start OIDC.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

KEYCLOAK_PORT="${KEYCLOAK_PORT:-8080}"
KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:${KEYCLOAK_PORT}}"
REDIS_HOST="${REDIS_HOST:-localhost}"
REDIS_PORT="${REDIS_PORT:-6379}"
IAM_STAFF_PORT="${IAM_STAFF_PORT:-8020}"
WAIT_IAM="${WAIT_IAM:-0}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-45}"

wait_http() {
  local url="$1"
  local label="$2"
  local i
  echo "Waiting for ${label} (${url}) ..."
  for i in $(seq 1 "$MAX_ATTEMPTS"); do
    if curl -sf "$url" >/dev/null 2>&1; then
      echo "  ${label} is ready."
      return 0
    fi
    sleep 2
  done
  echo "ERROR: ${label} did not become ready. Start infra: make infra-up" >&2
  return 1
}

wait_tcp() {
  local host="$1"
  local port="$2"
  local label="$3"
  local i
  echo "Waiting for ${label} (${host}:${port}) ..."
  for i in $(seq 1 "$MAX_ATTEMPTS"); do
    if python3 -c "import socket; s=socket.create_connection(('${host}', int('${port}')), 2); s.close()" 2>/dev/null; then
      echo "  ${label} is ready."
      return 0
    fi
    sleep 2
  done
  echo "ERROR: ${label} did not become ready on ${host}:${port}." >&2
  echo "IAM auth uses Redis. Start Docker Redis: USE_EXTERNAL_REDIS=false make infra-up" >&2
  return 1
}

wait_http "${KEYCLOAK_URL}/realms/staff/.well-known/openid-configuration" "Keycloak staff realm"
# Native IAM uses httpx against 127.0.0.1 (see KEYCLOAK_METADATA_URL). curl on
# localhost can succeed while IPv4 loopback is closed.
wait_http "http://127.0.0.1:${KEYCLOAK_PORT}/realms/staff/.well-known/openid-configuration" "Keycloak via 127.0.0.1"
wait_tcp "${REDIS_HOST}" "${REDIS_PORT}" "Redis"

if [[ "${WAIT_IAM}" == "1" ]]; then
  wait_http "http://localhost:${IAM_STAFF_PORT}/ping" "IAM staff API"
fi
