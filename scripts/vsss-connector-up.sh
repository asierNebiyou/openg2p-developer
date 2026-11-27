#!/usr/bin/env bash
# Restart only the registry connector against the Docker VSSS that is already running.
# Does not clone, install Odoo, or migrate PBMS. Use this when
# make vsss-pbms-connector-up already brought PBMS up and only the connector failed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/workspace-path.sh"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/run-service.sh"

OPENG2P_WORKSPACE="$(workspace_open)"
CONNECTOR_API_DIR="${OPENG2P_WORKSPACE}/registry-connector/api"
PARTNER_PORT="${VSSS_REGISTRY_PARTNER_API_PORT:-8022}"
CONNECTOR_PORT="${CONNECTOR_APP_PORT:-8070}"
CONNECTOR_DB_NAME="${CONNECTOR_DB_DBNAME:-connector}"
CONNECTOR_REDIS_DB="${CONNECTOR_REDIS_DB:-4}"
POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
REDIS_HOST="${REDIS_HOST:-localhost}"
REDIS_PORT="${REDIS_PORT:-6379}"

if [[ ! -d "${CONNECTOR_API_DIR}/.git" && ! -f "${CONNECTOR_API_DIR}/pyproject.toml" ]]; then
  echo "Missing ${CONNECTOR_API_DIR}" >&2
  echo "Run once: make vsss-pbms-connector-up" >&2
  exit 1
fi

echo "==> Connector database ${CONNECTOR_DB_NAME} ..."
PGPASSWORD="${POSTGRES_PASSWORD}" psql \
  -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_SUPERUSER:-postgres}" -d postgres \
  -tc "SELECT 1 FROM pg_database WHERE datname = '${CONNECTOR_DB_NAME}'" | grep -q 1 \
  || PGPASSWORD="${POSTGRES_PASSWORD}" psql \
    -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_SUPERUSER:-postgres}" -d postgres \
    -c "CREATE DATABASE ${CONNECTOR_DB_NAME};"

cat > "${CONNECTOR_API_DIR}/.env" <<EOF
CONNECTOR_APP_HOST=0.0.0.0
CONNECTOR_APP_PORT=${CONNECTOR_PORT}
CONNECTOR_LOG_LEVEL=INFO
CONNECTOR_DB_DRIVER=postgresql+asyncpg
CONNECTOR_DB_HOSTNAME=${POSTGRES_HOST}
CONNECTOR_DB_PORT=${POSTGRES_PORT}
CONNECTOR_DB_USERNAME=${POSTGRES_SUPERUSER:-postgres}
CONNECTOR_DB_PASSWORD=${POSTGRES_PASSWORD}
CONNECTOR_DB_DBNAME=${CONNECTOR_DB_NAME}
CONNECTOR_PARTNER_INGEST_BASE_URL=http://127.0.0.1:${PARTNER_PORT}
CONNECTOR_PARTNER_INGEST_TIMEOUT=30
CONNECTOR_CELERY_BROKER_URL=redis://${REDIS_HOST}:${REDIS_PORT}/${CONNECTOR_REDIS_DB}
CONNECTOR_CELERY_RESULT_BACKEND=redis://${REDIS_HOST}:${REDIS_PORT}/${CONNECTOR_REDIS_DB}
CONNECTOR_WORKER_MAX_ATTEMPTS=5
CONNECTOR_OTEL_ENABLED=false
CONNECTOR_STORE_RUN_PAYLOADS=true
CONNECTOR_STRICT_INCREMENTAL=true
CONNECTOR_REGISTRY_DB_DSN=postgresql://${POSTGRES_SUPERUSER:-postgres}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/vsss_registry_db
CONNECTOR_MASTER_DATA_DB_DSN=postgresql://${POSTGRES_SUPERUSER:-postgres}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/vsss_master_data_db
EOF

if [[ ! -x "${CONNECTOR_API_DIR}/venv/bin/python" ]]; then
  echo "==> Creating connector virtualenv ..."
  python3 -m venv "${CONNECTOR_API_DIR}/venv"
fi

if ! "${CONNECTOR_API_DIR}/venv/bin/python" -c "import openg2p_connector_service, uvicorn, asyncpg" >/dev/null 2>&1; then
  echo "==> Installing connector Python package ..."
  (
    cd "${CONNECTOR_API_DIR}"
    # shellcheck disable=SC1091
    source venv/bin/activate
    pip install -e .
  )
else
  echo "==> Connector package already installed. Skipping pip."
fi

echo "==> Start connector API + Celery ..."
run_service_stop "vsss-connector-api" "openg2p_connector_service.main" "${CONNECTOR_API_DIR}"
run_service_stop "vsss-connector-worker" "openg2p_connector_service.worker worker" "${CONNECTOR_API_DIR}"
run_service_stop "vsss-connector-beat" "openg2p_connector_service.worker beat" "${CONNECTOR_API_DIR}"

run_service "vsss-connector-api" "${CONNECTOR_API_DIR}" "${CONNECTOR_API_DIR}/.env" \
  "${CONNECTOR_API_DIR}/venv/bin/python" -m openg2p_connector_service.main
run_service "vsss-connector-worker" "${CONNECTOR_API_DIR}" "${CONNECTOR_API_DIR}/.env" \
  "${CONNECTOR_API_DIR}/venv/bin/celery" -A openg2p_connector_service.worker worker --loglevel=info
run_service "vsss-connector-beat" "${CONNECTOR_API_DIR}" "${CONNECTOR_API_DIR}/.env" \
  "${CONNECTOR_API_DIR}/venv/bin/celery" -A openg2p_connector_service.worker beat --loglevel=info --schedule=/tmp/celery-beat-vsss-connector.db

CONNECTOR_API_LOG="${ROOT_DIR}/generated/run/vsss-connector-api.log"
CONNECTOR_API_PID="${ROOT_DIR}/generated/run/vsss-connector-api.pid"

wait_for_url() {
  local url="$1" expect="$2" tries="${3:-30}" pidfile="${4:-}"
  local code i pid
  for i in $(seq 1 "$tries"); do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$url" || true)"
    if [[ " ${expect} " == *" ${code} "* ]]; then
      return 0
    fi
    if [[ -n "$pidfile" && -f "$pidfile" ]]; then
      pid="$(tr -d '[:space:]' <"$pidfile")"
      if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
        echo "Process in ${pidfile} exited while waiting for ${url}" >&2
        return 1
      fi
    fi
    sleep 2
  done
  return 1
}

echo "==> Waiting for connector API on :${CONNECTOR_PORT} ..."
fail=0
if ! wait_for_url "http://127.0.0.1:${CONNECTOR_PORT}/health" 200 30 "$CONNECTOR_API_PID"; then
  echo "Connector API did not stay up on :${CONNECTOR_PORT}." >&2
  fail=1
fi

check() {
  local name="$1" url="$2" expect="${3:-200}"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$url" || true)"
  if [[ "$code" == "$expect" ]]; then
    echo "OK  ${name} ${url} -> ${code}"
  else
    echo "FAIL ${name} ${url} -> ${code} (wanted ${expect})" >&2
    fail=1
  fi
}

check "Connector" "http://127.0.0.1:${CONNECTOR_PORT}/health" 200
check "Connector ready" "http://127.0.0.1:${CONNECTOR_PORT}/health/ready" 200

if pgrep -f "openg2p_connector_service.worker worker" >/dev/null; then
  echo "OK  connector celery worker is running"
else
  echo "FAIL connector celery worker is not running" >&2
  fail=1
fi

if [[ "$fail" -ne 0 ]]; then
  if [[ -f "$CONNECTOR_API_LOG" ]]; then
    echo "---- ${CONNECTOR_API_LOG} (last 40 lines) ----" >&2
    tail -n 40 "$CONNECTOR_API_LOG" >&2 || true
  fi
  echo "Connector failed. Log: ${CONNECTOR_API_LOG}" >&2
  exit 1
fi

echo
echo "Connector is up."
echo "  Connector : http://127.0.0.1:${CONNECTOR_PORT}/health"
echo "  Partner   : http://127.0.0.1:${PARTNER_PORT}"
