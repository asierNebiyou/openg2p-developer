#!/usr/bin/env bash
# Build local VSSS Docker images (not published on Hub yet) for docker-vsss-up.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/workspace-path.sh"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

OPENG2P_WORKSPACE="$(workspace_open)"
PRODUCT_REPO="${OPENG2P_WORKSPACE}/village-social-security-registry"
BUILD_SH="${PRODUCT_REPO}/docker/scripts/build.sh"

if [[ ! -x "$BUILD_SH" && ! -f "$BUILD_SH" ]]; then
  echo "ERROR: VSSS product repo not found at ${PRODUCT_REPO}" >&2
  echo "Run: make clone PROFILE=vsss" >&2
  exit 1
fi

STAFF_IMAGE="${VSSS_REGISTRY_STAFF_API_IMAGE:-openg2p/openg2p-vsss-staff-portal-api:develop}"
PARTNER_IMAGE="${VSSS_REGISTRY_PARTNER_API_IMAGE:-openg2p/openg2p-vsss-partner-api:develop}"
CELERY_IMAGE="${VSSS_REGISTRY_CELERY_IMAGE:-openg2p/openg2p-vsss-celery:develop}"
SEED_IMAGE="${VSSS_REGISTRY_DB_SEED_IMAGE:-openg2p/openg2p-vsss-db-seed:develop}"

need_build=0
for img in "$STAFF_IMAGE" "$PARTNER_IMAGE" "$CELERY_IMAGE" "$SEED_IMAGE"; do
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    echo "Missing local image: ${img}"
    need_build=1
  fi
done

if [[ "${FORCE_VSSS_BUILD:-0}" != "1" && "$need_build" -eq 0 ]]; then
  echo "VSSS images already present locally (set FORCE_VSSS_BUILD=1 to rebuild)."
  exit 0
fi

echo "============================================="
echo " Building VSSS Docker images"
echo " Repo: ${PRODUCT_REPO}"
echo "============================================="

# API / celery images (docker/ context via build.sh). No Hub push required.
bash "$BUILD_SH" \
  staff-portal-api/develop.txt \
  partner-api/develop.txt \
  celery/develop.txt

# db-seed uses repo-root context (Dockerfile COPY paths).
echo "Building ${SEED_IMAGE} ..."
docker build \
  -f "${PRODUCT_REPO}/docker/db-seed/Dockerfile" \
  -t "${SEED_IMAGE}" \
  "${PRODUCT_REPO}"

# If staff image tag from develop.txt differs from compose pin, retag.
BUILT_STAFF="openg2p/openg2p-vsss-staff-portal-api:develop"
if [[ "$STAFF_IMAGE" != "$BUILT_STAFF" ]]; then
  docker tag "$BUILT_STAFF" "$STAFF_IMAGE" || true
fi

echo "VSSS images ready:"
docker image ls --format 'table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}' \
  | grep -E 'vsss|REPOSITORY' || true
