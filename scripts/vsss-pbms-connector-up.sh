#!/usr/bin/env bash
# First-time bring-up of PBMS (Odoo + staff API + Celery) and the registry
# connector against the Docker VSSS stack that is already running.
#
# Does not recreate VSSS, and does not start a second native registry.
# SPAR and G2P Bridge are a later step (PBMS_WITH_SPAR / PBMS_WITH_BRIDGE stay false).
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

set_env_key() {
  local key="$1" value="$2" file="${ROOT_DIR}/.env"
  if grep -q "^${key}=" "$file"; then
    # macOS sed needs a backup suffix; empty string is fine.
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$file"
    rm -f "${file}.bak"
  else
    printf '\n%s=%s\n' "$key" "$value" >>"$file"
  fi
  export "${key}=${value}"
}

echo "==> VSSS partner API must already be up (Docker) ..."
partner_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${PARTNER_PORT}/ping" || true)"
if [[ "$partner_code" != "200" ]]; then
  echo "VSSS partner API on :${PARTNER_PORT} returned '${partner_code}', not 200." >&2
  echo "Start it first: make docker-vsss-up" >&2
  exit 1
fi
echo "Partner API http://127.0.0.1:${PARTNER_PORT}/ping -> 200"

echo "==> Point PBMS at the Docker VSSS database (no native registry) ..."
set_env_key PBMS_REGISTRY_VARIANT village-social-security-registry
set_env_key PBMS_WITH_REGISTRY false
set_env_key PBMS_WITH_SPAR false
set_env_key PBMS_WITH_BRIDGE false

echo "==> Clone Odoo + PBMS (only repos that are not already on disk) ..."
keys=()
[[ -f "${OPENG2P_WORKSPACE}/odoo17/odoo-bin" ]] || keys+=(odoo)
[[ -d "${OPENG2P_WORKSPACE}/openg2p-odoo-commons/.git" ]] || keys+=(odoo_commons)
[[ -f "${OPENG2P_WORKSPACE}/pbms/odoo/g2p_pbms/__manifest__.py" ]] || keys+=(pbms)
[[ -d "${OPENG2P_WORKSPACE}/pbms-connectors/extensions/registry-adapters" ]] || keys+=(pbms_connectors)
[[ -f "${OPENG2P_WORKSPACE}/registry-connector/api/pyproject.toml" ]] || keys+=(registry_connector)
if [[ ${#keys[@]} -gt 0 ]]; then
  CLONE_REPO_KEYS="${keys[*]}" bash "${ROOT_DIR}/scripts/clone-repos.sh"
else
  echo "Odoo, Odoo Commons, PBMS, and the registry connector are already present."
fi

echo "==> Generate PBMS env (registry DB = vsss_registry_db) ..."
bash "${ROOT_DIR}/scripts/generate-config.sh"
if ! grep -q 'vsss_registry_db' "${ROOT_DIR}/generated/pbms/celery-workers.env"; then
  echo "generated/pbms/celery-workers.env is not pointed at vsss_registry_db" >&2
  exit 1
fi

echo "==> Install PBMS Python deps and migrate databases ..."
make install-odoo
make install-pbms-bg-tasks
# Install the PBMS Odoo apps on the first init. A later Apps-menu click is not required.
export PBMS_ODOO_INIT_MODULES="${PBMS_ODOO_INIT_MODULES:-base,queue_job,g2p_pbms}"
make pbms-init
# make pbms-init stops once ir_module_module exists, even when g2p_pbms
# never finished installing. Install the missing apps in that case.
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/pbms-odoo.sh"
pbms_odoo_load_env
g2p_state="$(PGPASSWORD="${PBMS_DB_PASSWORD}" psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${PBMS_DB_USER}" -d "${PBMS_DB_NAME}" -tAc "SELECT state FROM ir_module_module WHERE name = 'g2p_pbms'" || true)"
if [[ "${g2p_state}" != "installed" ]]; then
  echo "==> Installing g2p_pbms (current state: ${g2p_state:-missing}) ..."
  "$(pbms_odoo_python_bin)" "${ODOO_PATH}/odoo-bin" -c "${PBMS_ODOO_CONF}" \
    -d "${PBMS_DB_NAME}" -i "${PBMS_ODOO_INIT_MODULES}" --stop-after-init --without-demo=all
fi
make init-pbms-bg-tasks

echo "==> Start PBMS staff API + Celery beat + worker ..."
bash "${ROOT_DIR}/scripts/start-pbms-bg-tasks.sh"

echo "==> Start PBMS Odoo in the background ..."
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/pbms-odoo.sh"
pbms_odoo_load_env
run_service_stop "pbms-odoo" "odoo-bin" "${PBMS_ODOO_CONF}"
run_service "pbms-odoo" "${ODOO_PATH}" "${ROOT_DIR}/.env" \
  python "${ODOO_PATH}/odoo-bin" -c "${PBMS_ODOO_CONF}"

echo "==> PBMS checks (connector is separate) ..."
fail=0
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
check "VSSS partner" "http://127.0.0.1:${PARTNER_PORT}/ping" 200
check "PBMS staff API" "http://127.0.0.1:${PBMS_STAFF_API_PORT:-8050}/docs" 200
check "PBMS Odoo" "http://127.0.0.1:${PBMS_HTTP_PORT:-8069}/web/login" 200
if pgrep -f "openg2p_bg_task_celery_beat_producers.main.celery_app beat" >/dev/null; then
  echo "OK  PBMS celery beat is running"
else
  echo "FAIL PBMS celery beat is not running" >&2
  fail=1
fi
if pgrep -f "bg_task_worker_queue" >/dev/null; then
  echo "OK  PBMS celery worker is running"
else
  echo "FAIL PBMS celery worker is not running" >&2
  fail=1
fi
if [[ "$fail" -ne 0 ]]; then
  echo "PBMS checks failed. Logs: ${ROOT_DIR}/generated/run/" >&2
  exit 1
fi

echo "==> Connector only (retry later with: make vsss-connector-up) ..."
bash "${ROOT_DIR}/scripts/vsss-connector-up.sh"

echo
echo "PBMS and the connector are up against Docker VSSS."
echo "  VSSS partner : http://127.0.0.1:${PARTNER_PORT}/docs"
echo "  PBMS Odoo    : http://127.0.0.1:${PBMS_HTTP_PORT:-8069}"
echo "  PBMS API     : http://127.0.0.1:${PBMS_STAFF_API_PORT:-8050}/docs"
echo "  Connector    : http://127.0.0.1:${CONNECTOR_PORT}/health"
echo "  Registry DB  : vsss_registry_db (PBMS Celery SR connection)"
echo "SPAR and G2P Bridge are not started. Next step when you want disbursement."
echo "If only the connector fails, rerun: make vsss-connector-up"
