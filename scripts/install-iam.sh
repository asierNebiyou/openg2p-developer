#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/resolve-python.sh"

resolve_path() {
  local path="$1"
  if [[ "$path" != /* ]]; then
    path="${ROOT_DIR}/${path}"
  fi
  local dir part
  dir="$(dirname "$path")"
  part="$(basename "$path")"
  echo "$(cd "$dir" && pwd)/${part}"
}

OPENG2P_WORKSPACE="$(resolve_path "${OPENG2P_WORKSPACE:-../openg2p-workspace}")"
IAM_ROOT="${OPENG2P_WORKSPACE}/iam-service"
IAM_API_DIR="${IAM_ROOT}/iam-staff-portal-api"
IAM_CORE_DIR="${IAM_ROOT}/iam-core"

for dir in "$IAM_API_DIR" "$IAM_CORE_DIR"; do
  if [[ ! -d "$dir" ]]; then
    echo "Missing ${dir}. Run: make clone" >&2
    exit 1
  fi
done

PYTHON_BIN="$(resolve_python_bin)"
if ! resolve_python_meets_minimum "$PYTHON_BIN"; then
  echo "Python >=3.10 required for IAM. Set OPENG2P_PYTHON in .env." >&2
  exit 1
fi

if [[ -d "${IAM_API_DIR}/venv" ]] && ! resolve_python_meets_minimum "${IAM_API_DIR}/venv/bin/python" 2>/dev/null; then
  echo "Recreating IAM venv with ${PYTHON_BIN} ..."
  rm -rf "${IAM_API_DIR}/venv"
fi

if [[ ! -d "${IAM_API_DIR}/venv" ]]; then
  "${PYTHON_BIN}" -m venv "${IAM_API_DIR}/venv"
fi

(
  cd "$IAM_API_DIR"
  # shellcheck disable=SC1091
  source venv/bin/activate
  pip install --upgrade pip wheel
  if [[ -f requirements.txt ]]; then
    pip install -r requirements.txt
  fi
  pip install "$IAM_CORE_DIR" greenlet openg2p-fastapi-auth
  pip install "$IAM_API_DIR"
)

echo "Installed IAM staff portal API and iam-core."
