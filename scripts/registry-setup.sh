#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VARIANT="${1:-}"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/registry-variant.sh"
source "${ROOT_DIR}/scripts/lib/extension-manifest.sh"

if [[ -z "$VARIANT" ]]; then
  echo "Usage: registry-setup.sh <variant>" >&2
  exit 1
fi

registry_variant_validate "$VARIANT"
registry_variant_paths "$VARIANT"

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example"
fi

# shellcheck disable=SC1091
source .env

LOAD_SAMPLE_DATA="${LOAD_SAMPLE_DATA:-false}"
LOAD_TEMPLATES="${LOAD_TEMPLATES:-false}"
LOAD_IMAGES="${LOAD_IMAGES:-false}"

case "$VARIANT" in
  farmer-registry)
    UI_PORT="${FARMER_REGISTRY_UI_PORT:-3001}"
    RUN_TARGET="farmer-registry-run"
    SEED_TARGET="farmer-registry-seed"
    ;;
  national-social-registry)
    UI_PORT="${NSR_REGISTRY_UI_PORT:-3002}"
    RUN_TARGET="nsr-registry-run"
    SEED_TARGET="nsr-registry-seed"
    ;;
  village-social-security-registry)
    UI_PORT="${VSSS_REGISTRY_UI_PORT:-3020}"
    RUN_TARGET="vsss-registry-run"
    SEED_TARGET="vsss-registry-seed"
    ;;
  *)
    extension_manifest_load "$VARIANT"
    UI_PORT="${EXTENSION_UI_PORT}"
    RUN_TARGET="extension-run"
    SEED_TARGET="extension-seed"
    ;;
esac

echo "============================================="
echo " ${LABEL} one-time setup"
echo " Sample data: ${LOAD_SAMPLE_DATA}"
echo "============================================="

bash "${ROOT_DIR}/scripts/generate-config.sh" >/dev/null

bash "${ROOT_DIR}/scripts/install-iam.sh"
bash "${ROOT_DIR}/scripts/init-iam.sh"
bash "${ROOT_DIR}/scripts/install-awe.sh"
bash "${ROOT_DIR}/scripts/init-awe.sh"
bash "${ROOT_DIR}/scripts/install-master-data.sh"

VARIANT="$VARIANT" bash "${ROOT_DIR}/scripts/install-registry-extension.sh"
bash "${ROOT_DIR}/scripts/install-registry-ui.sh"
VARIANT="$VARIANT" bash "${ROOT_DIR}/scripts/install-registry-db-seed.sh"

bash "${ROOT_DIR}/scripts/postgres-ensure-extension-databases.sh" "$VARIANT" || {
  echo "[registry-setup] Postgres databases not ready. Run: make infra-up" >&2
  exit 1
}

bash "${ROOT_DIR}/scripts/id-generator-wait.sh" || {
  echo "[registry-setup] ID Generator not ready. Run: make infra-up" >&2
  exit 1
}

echo
echo "[registry-setup] Initializing Master Data for ${LABEL} ..."
VARIANT="$VARIANT" bash "${ROOT_DIR}/scripts/init-master-data.sh" "$VARIANT"

echo
echo "[registry-setup] Migrating schema and seeding ${LABEL} configuration ..."
VARIANT="$VARIANT" bash "${ROOT_DIR}/scripts/migrate-registry-db.sh"
# Geo/codelists live in Master Data; enable when sample data is requested.
if [[ "$LOAD_SAMPLE_DATA" == "true" && "${LOAD_GEO_DATA:-}" != "false" ]]; then
  LOAD_GEO_DATA=true
fi
VARIANT="$VARIANT" \
  LOAD_SAMPLE_DATA="$LOAD_SAMPLE_DATA" \
  LOAD_GEO_DATA="${LOAD_GEO_DATA:-false}" \
  LOAD_TEMPLATES="$LOAD_TEMPLATES" \
  LOAD_IMAGES="$LOAD_IMAGES" \
  bash "${ROOT_DIR}/scripts/seed-registry-db.sh" "$VARIANT"

if registry_variant_is_custom "$VARIANT"; then
  bash "${ROOT_DIR}/scripts/keycloak-ensure-extension-clients.sh" "$VARIANT" || true
fi

echo
echo "${LABEL} setup complete."
if [[ "$RUN_TARGET" == "extension-run" ]]; then
  echo "  make extension-run NAME=${VARIANT}"
else
  echo "  make ${RUN_TARGET}"
fi
echo "  Staff UI: http://localhost:${UI_PORT} (staff / staff)"
if [[ "$LOAD_SAMPLE_DATA" != "true" ]]; then
  echo
  echo "Optional demo registrants and sub-tables:"
  if [[ "$SEED_TARGET" == "extension-seed" ]]; then
    echo "  LOAD_SAMPLE_DATA=true make extension-seed NAME=${VARIANT}"
  else
    echo "  LOAD_SAMPLE_DATA=true make ${SEED_TARGET}"
  fi
  if [[ "$VARIANT" == "farmer-registry" ]]; then
    echo "  (Geo master data loads automatically when sample data is enabled.)"
  fi
fi
