#!/usr/bin/env bash
# Pick a Python interpreter for OpenG2P venvs (Gen2 requires >=3.10).
resolve_python_bin() {
  if [[ -n "${OPENG2P_PYTHON:-}" ]]; then
    echo "${OPENG2P_PYTHON}"
    return 0
  fi
  local candidate
  for candidate in python3.13 python3.12 python3.11 python3.10; do
    if command -v "$candidate" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  echo "python3"
}

resolve_python_major_minor() {
  local bin="$1"
  "$bin" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")'
}

resolve_python_meets_minimum() {
  local bin="$1"
  local min_major="${2:-3}"
  local min_minor="${3:-10}"
  "$bin" - <<PY
import sys
sys.exit(0 if sys.version_info >= (${min_major}, ${min_minor}) else 1)
PY
}
