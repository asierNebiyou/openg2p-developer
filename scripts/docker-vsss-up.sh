#!/usr/bin/env bash
# Docker-only Village Social Security System: infra + IAM + AWE + VSSS services + seed.
# Builds VSSS images locally when missing (they are not on Docker Hub yet).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/docker-registry.sh"

docker_registry_resolve_compose
docker_registry_compose_files
docker_registry_prepare_env vsss

# Ensure product repo exists for image build / seed content.
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/workspace-path.sh"
OPENG2P_WORKSPACE="$(workspace_open)"
if [[ ! -d "${OPENG2P_WORKSPACE}/village-social-security-registry/.git" ]]; then
  echo "VSSS product repo missing — cloning profile village-social-security-registry ..."
  bash "${ROOT_DIR}/scripts/clone-repos.sh" village-social-security-registry
fi

bash "${ROOT_DIR}/scripts/docker-vsss-build.sh"

docker_registry_up_variant vsss
