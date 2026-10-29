#!/usr/bin/env bash
# Build the VSSS Docker images locally (not published on Hub yet) for
# docker-vsss-up.
#
# The VSSS repo now follows the inverted build model (same as mowsa-nsr): each
# docker/<svc>/Dockerfile is a thin `FROM openg2p/openg2p-registry-<svc>:${RP_VERSION}`
# layer that pip-installs the vsss-extension, built with the repo root as
# context. So this script is a plain `docker build` per service — there is no
# docker/scripts/build.sh and no per-version .txt manifest any more.
#
# What this replaces, and why:
#   * it called `build.sh staff-portal-api/develop.txt partner-api/develop.txt
#     celery/develop.txt` — hardcoded `develop`, so it ignored the pinned image
#     versions entirely and built against registry-platform's develop branch
#     whatever .env said;
#   * it then retagged ONLY the staff image to the pinned tag. partner, celery
#     and db-seed kept their `:develop` tags, so compose looked for pinned tags
#     that did not exist locally and fell through to a Hub pull.
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

if [[ ! -d "$PRODUCT_REPO" ]]; then
  echo "ERROR: VSSS product repo not found at ${PRODUCT_REPO}" >&2
  echo "Run: make clone PROFILE=village-social-security-registry" >&2
  exit 1
fi

STAFF_IMAGE="${VSSS_REGISTRY_STAFF_API_IMAGE:-openg2p/openg2p-vsss-staff-portal-api:1.2.0}"
PARTNER_IMAGE="${VSSS_REGISTRY_PARTNER_API_IMAGE:-openg2p/openg2p-vsss-partner-api:1.2.0}"
CELERY_IMAGE="${VSSS_REGISTRY_CELERY_IMAGE:-openg2p/openg2p-vsss-celery:1.2.0}"
SEED_IMAGE="${VSSS_REGISTRY_DB_SEED_IMAGE:-openg2p/openg2p-vsss-db-seed:1.2.0}"

# service dir -> target image, in build order.
SERVICES=(
  "staff-portal-api:${STAFF_IMAGE}"
  "partner-api:${PARTNER_IMAGE}"
  "celery:${CELERY_IMAGE}"
  "db-seed:${SEED_IMAGE}"
)

need_build=0
for entry in "${SERVICES[@]}"; do
  img="${entry#*:}"
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    echo "Missing local image: ${img}"
    need_build=1
  fi
done

if [[ "${FORCE_VSSS_BUILD:-0}" != "1" && "$need_build" -eq 0 ]]; then
  echo "VSSS images already present locally (set FORCE_VSSS_BUILD=1 to rebuild)."
  exit 0
fi

# The registry-platform version the thin images extend. Each Dockerfile already
# declares `ARG RP_VERSION=<pin>`; only override it deliberately. Taking the
# default from the Dockerfile keeps this script from silently disagreeing with
# the VSSS repo's own pin (and with its Helm chart, which CI checks in lockstep).
RP_VERSION="${RP_VERSION:-${REGISTRY_PLATFORM_VERSION:-}}"

# Prefer Docker Engine arch over `uname` (Rosetta shells report x86_64 on Apple Silicon).
if [[ -z "${BUILD_PLATFORM:-}" ]]; then
  _arch="$(docker version -f '{{.Server.Arch}}' 2>/dev/null || true)"
  case "${_arch}" in
    aarch64|arm64) BUILD_PLATFORM="linux/arm64" ;;
    x86_64|amd64)  BUILD_PLATFORM="linux/amd64" ;;
    *)
      case "$(uname -m)" in
        arm64|aarch64) BUILD_PLATFORM="linux/arm64" ;;
        *)             BUILD_PLATFORM="linux/amd64" ;;
      esac
      ;;
  esac
fi
export BUILD_PLATFORM

echo "============================================="
echo " Building VSSS Docker images"
echo " Repo     : ${PRODUCT_REPO}"
echo " Platform : ${BUILD_PLATFORM}"
echo " RP_VERSION override : ${RP_VERSION:-<use each Dockerfile default>}"
echo "============================================="

# Prebuild the extension wheel on the host. The thin Dockerfiles install that
# wheel with --no-deps so the image build never needs PyPI (Docker Desktop and
# some CI runners can pull Hub but cannot reach pypi.org for hatchling).
EXT_SRC="${PRODUCT_REPO}/openg2p-registry-vsss-extension"
WHEEL_DIR="${PRODUCT_REPO}/docker/.build-wheels"
if [[ ! -d "$EXT_SRC" ]]; then
  echo "ERROR: extension source not found at ${EXT_SRC}" >&2
  exit 1
fi
echo "--- prebuilding extension wheel -> ${WHEEL_DIR}"
rm -rf "${WHEEL_DIR:?}/"*
mkdir -p "$WHEEL_DIR"
python3 -m pip wheel --no-deps -w "$WHEEL_DIR" "$EXT_SRC"
WHEEL_COUNT="$(find "$WHEEL_DIR" -maxdepth 1 -name 'openg2p_registry_vsss_extension-*.whl' | wc -l | tr -d ' ')"
if [[ "$WHEEL_COUNT" -lt 1 ]]; then
  echo "ERROR: no openg2p_registry_vsss_extension-*.whl produced in ${WHEEL_DIR}" >&2
  exit 1
fi
ls -1 "$WHEEL_DIR"/openg2p_registry_vsss_extension-*.whl

for entry in "${SERVICES[@]}"; do
  svc="${entry%%:*}"
  img="${entry#*:}"
  dockerfile="${PRODUCT_REPO}/docker/${svc}/Dockerfile"

  if [[ ! -f "$dockerfile" ]]; then
    echo "ERROR: ${dockerfile} not found." >&2
    echo "The VSSS repo layout changed — expected a thin Dockerfile per service." >&2
    exit 1
  fi

  build_args=()
  [[ -n "$RP_VERSION" ]] && build_args+=(--build-arg "RP_VERSION=${RP_VERSION}")

  echo "--- ${svc} -> ${img}"
  # Repo-root context: thin Dockerfiles COPY the prebuilt wheel from docker/.build-wheels/.
  # --pull=false: use the local base image when Hub metadata checks flake
  # (context deadline exceeded) even though the pin is already present.
  docker build \
    --platform "${BUILD_PLATFORM}" \
    --pull=false \
    "${build_args[@]}" \
    -f "$dockerfile" \
    -t "$img" \
    "$PRODUCT_REPO"
done

echo
echo "VSSS images ready:"
for entry in "${SERVICES[@]}"; do
  img="${entry#*:}"
  printf '  %-56s %s\n' "$img" "$(docker image inspect -f '{{.Id}}' "$img" 2>/dev/null | cut -c8-19)"
done
