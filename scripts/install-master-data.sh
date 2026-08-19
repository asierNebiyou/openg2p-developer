#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/workspace-path.sh"

OPENG2P_WORKSPACE="$(workspace_open)"
MASTER_DATA_API_DIR="${OPENG2P_WORKSPACE}/master-data-service/master-data-api"
IAM_CORE_DIR="${OPENG2P_WORKSPACE}/iam-service/iam-core"

if [[ ! -d "$MASTER_DATA_API_DIR" ]]; then
  echo "Missing ${MASTER_DATA_API_DIR}. Run: make clone PROFILE=registry" >&2
  exit 1
fi

if [[ ! -d "$IAM_CORE_DIR" ]]; then
  echo "Missing ${IAM_CORE_DIR}. Run: make clone PROFILE=registry" >&2
  exit 1
fi

# iam-core is a local workspace package (not on PyPI). Create the venv and
# install it first so `pip install -e .` can resolve the MDS dependency.
SKIP_EDITABLE_INSTALL=1 bash "${ROOT_DIR}/scripts/install-python-project.sh" "$MASTER_DATA_API_DIR"

(
  cd "$MASTER_DATA_API_DIR"
  # shellcheck disable=SC1091
  source venv/bin/activate
  pip install "$IAM_CORE_DIR" greenlet openg2p-fastapi-auth 'psycopg2-binary>=2.9.12'
  pip install -e .
)

SEED_DIR="${OPENG2P_WORKSPACE}/master-data-service/docker/db-seed"
if [[ -d "$SEED_DIR" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/scripts/lib/resolve-python.sh"
  SEED_PYTHON="$(resolve_python_bin)"
  if [[ -d "${SEED_DIR}/venv" ]] && ! resolve_python_meets_minimum "${SEED_DIR}/venv/bin/python" 2>/dev/null; then
    rm -rf "${SEED_DIR}/venv"
  fi
  if [[ ! -x "${SEED_DIR}/venv/bin/python" ]]; then
    echo "Installing Master Data db-seed Python dependencies ..."
    "${SEED_PYTHON}" -m venv "${SEED_DIR}/venv"
  fi
  (
    # shellcheck disable=SC1091
    source "${SEED_DIR}/venv/bin/activate"
    pip install --upgrade pip wheel
    pip install 'psycopg2-binary>=2.9.12'
  )
fi

echo "Installed Master Data API (and db-seed venv if present)."
