#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

OPENG2P_WORKSPACE="${OPENG2P_WORKSPACE:-../openg2p-workspace}"
OPENG2P_WORKSPACE="$(cd "$ROOT_DIR" && cd "$OPENG2P_WORKSPACE" && pwd)"
PROJECT_DIR="$1"
VENV_NAME="${2:-venv}"

if [[ -z "${PROJECT_DIR}" ]]; then
  echo "Usage: $0 <project-dir> [venv-name]" >&2
  exit 1
fi

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "Project directory not found: ${PROJECT_DIR}" >&2
  exit 1
fi

cd "$PROJECT_DIR"

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/lib/resolve-python.sh"
PYTHON_BIN="$(resolve_python_bin)"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "Python not found: ${PYTHON_BIN} (set OPENG2P_PYTHON in .env)" >&2
  exit 1
fi
if ! resolve_python_meets_minimum "$PYTHON_BIN"; then
  echo "Python >=3.10 required (got $(resolve_python_major_minor "$PYTHON_BIN")). Set OPENG2P_PYTHON in .env." >&2
  exit 1
fi

if [[ -d "$VENV_NAME" ]]; then
  if ! resolve_python_meets_minimum "${VENV_NAME}/bin/python" 2>/dev/null; then
    echo "Recreating ${PROJECT_DIR}/${VENV_NAME} with ${PYTHON_BIN} (existing venv is Python <3.10) ..."
    rm -rf "$VENV_NAME"
  fi
fi

if [[ ! -d "$VENV_NAME" ]]; then
  "${PYTHON_BIN}" -m venv "$VENV_NAME"
fi

# shellcheck disable=SC1091
source "${VENV_NAME}/bin/activate"
pip install --upgrade pip wheel

install_requirements() {
  local req_file="$1"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    # Strip trailing comments, but keep pip URL fragments (#subdirectory=, #egg=).
    line="${line%%[[:space:]]#*}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    if [[ "$line" == psycopg2-binary* ]]; then
      # Product repos may pin 2.9.9; cp314 needs >=2.9.12 (prebuilt wheel).
      pip install 'psycopg2-binary>=2.9.12'
    else
      pip install "$line"
    fi
  done < "$req_file"
}

if [[ -f test-requirements.txt ]]; then
  install_requirements test-requirements.txt
fi

if [[ -f requirements.txt ]]; then
  install_requirements requirements.txt
fi

if [[ -f pyproject.toml ]] && [[ "${SKIP_EDITABLE_INSTALL:-}" != "1" ]]; then
  pip install -e .
fi

echo "Python environment ready in ${PROJECT_DIR}/${VENV_NAME}"
