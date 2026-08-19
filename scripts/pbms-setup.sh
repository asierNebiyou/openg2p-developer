#!/usr/bin/env bash
# One-time PBMS bootstrap: infra, deps, registry (optional), Odoo + bg-task DBs.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/pbms-bg-tasks.sh"
pbms_bg_tasks_load_env

PROFILE="${PROFILE:-pbms}"
PBMS_WITH_REGISTRY="${PBMS_WITH_REGISTRY:-true}"

echo "==> Cloning repositories (PROFILE=${PROFILE}) ..."
make clone PROFILE="${PROFILE}"

echo "==> Generating configs ..."
make generate

echo "==> Starting infrastructure ..."
make infra-up

echo "==> Installing Odoo dependencies ..."
make install-odoo

echo "==> Installing PBMS bg-task dependencies ..."
make install-pbms-bg-tasks

if [[ "${PBMS_WITH_REGISTRY}" == "true" ]]; then
  case "${PBMS_REGISTRY_VARIANT}" in
    farmer-registry)
      echo "==> Bootstrapping Farmer Registry (${PBMS_REGISTRY_VARIANT}) ..."
      make farmer-setup
      ;;
    national-social-registry)
      echo "==> Bootstrapping NSR (${PBMS_REGISTRY_VARIANT}) ..."
      make nsr-setup
      ;;
    village-social-security-registry)
      echo "==> Bootstrapping VSSS (${PBMS_REGISTRY_VARIANT}) ..."
      make vsss-setup
      ;;
    *)
      echo "==> Bootstrapping custom registry extension (${PBMS_REGISTRY_VARIANT}) ..."
      make extension-setup NAME="${PBMS_REGISTRY_VARIANT}"
      ;;
  esac
fi

echo "==> Initializing PBMS Odoo database ..."
make pbms-init

echo "==> Migrating PBMS bg-task database ..."
make init-pbms-bg-tasks

echo
echo "PBMS setup complete."
echo "  Start full stack: make pbms-run"
echo "  Odoo UI        : http://localhost:${PBMS_HTTP_PORT:-8069}"
