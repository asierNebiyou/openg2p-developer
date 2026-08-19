#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

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
AWE_DIR="${OPENG2P_WORKSPACE}/awe"

if [[ ! -d "$AWE_DIR" ]]; then
  echo "AWE repo not found at ${AWE_DIR}. Run: make clone" >&2
  exit 1
fi

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/resolve-python.sh"
PYTHON_BIN="$(resolve_python_bin)"
if ! resolve_python_meets_minimum "$PYTHON_BIN" 3 11; then
  for PYTHON_BIN in python3.13 python3.12 python3.11; do
    if command -v "$PYTHON_BIN" >/dev/null 2>&1 && resolve_python_meets_minimum "$PYTHON_BIN" 3 11; then
      break
    fi
    PYTHON_BIN=""
  done
fi
if [[ -z "$PYTHON_BIN" ]] || ! resolve_python_meets_minimum "$PYTHON_BIN" 3 11; then
  echo "AWE requires Python 3.11+. Set OPENG2P_PYTHON in .env." >&2
  exit 1
fi

if [[ -d "${AWE_DIR}/venv" ]] && ! resolve_python_meets_minimum "${AWE_DIR}/venv/bin/python" 3 11 2>/dev/null; then
  echo "Recreating AWE venv with ${PYTHON_BIN} ..."
  rm -rf "${AWE_DIR}/venv"
fi

if [[ ! -d "${AWE_DIR}/venv" ]]; then
  "${PYTHON_BIN}" -m venv "${AWE_DIR}/venv"
fi

install_awe_editable() {
  local pyproject="${AWE_DIR}/pyproject.toml"
  local backup=""
  if [[ -f "$pyproject" ]] && grep -qE '^version[[:space:]]*=[[:space:]]*"develop"[[:space:]]*$' "$pyproject"; then
    # Upstream AWE uses version = "develop" (not PEP 440). Patch temporarily for pip install -e .
    backup="${pyproject}.openg2p-dev.bak"
    cp "$pyproject" "$backup"
    sed -i 's/^version = "develop"/version = "0.0.0.dev0"/' "$pyproject"
  fi

  (
    cd "$AWE_DIR"
    # shellcheck disable=SC1091
    source venv/bin/activate
    pip install --upgrade pip wheel
    pip install -e .
  )

  if [[ -n "$backup" && -f "$backup" ]]; then
    mv -f "$backup" "$pyproject"
  fi
}

install_awe_editable

if [[ -d "${AWE_DIR}/ui" ]] && command -v npm >/dev/null 2>&1; then
  echo "Installing AWE admin UI dependencies ..."
  (
    cd "${AWE_DIR}/ui"
    if [[ -f package-lock.json ]]; then
      npm ci
    else
      npm install
    fi
  )
  bash "${ROOT_DIR}/scripts/generate-config.sh" >/dev/null
  AWE_API_PORT="${AWE_API_PORT:-8030}" AWE_UI_PORT="${AWE_UI_PORT:-8031}" \
    bash "${ROOT_DIR}/scripts/lib/ensure-awe-ui-vite-config.sh" "${AWE_DIR}/ui"
  bash "${ROOT_DIR}/scripts/lib/ensure-awe-ui-config.sh" "${AWE_DIR}/ui"
else
  echo "Skipping AWE admin UI install (ui/ missing or npm not on PATH)."
fi

echo "Installed Approval Workflow Engine (AWE) in ${AWE_DIR}/venv"
