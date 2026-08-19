#!/usr/bin/env bash
# Start shared infra containers; auto-pick free host ports before compose up.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example"
fi

# shellcheck disable=SC1091
source .env

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/ensure-free-ports.sh"
docker_registry_ensure_ports infra

profiles=(--profile infra)
if [[ "${USE_EXTERNAL_REDIS:-false}" != "true" ]]; then
  profiles+=(--profile with-redis)
fi

COMPOSE="${COMPOSE:-docker compose}"
# shellcheck disable=SC2206
COMPOSE_CMD=(${COMPOSE})

COMPOSE_FILES=(
  -f compose/docker-compose.infra.yml
  -f compose/docker-compose.commons.yml
  -f compose/docker-compose.registry.yml
  -f compose/docker-compose.pbms.yml
  -f compose/docker-compose.bridge.yml
  -f compose/docker-compose.spar.yml
)

"${COMPOSE_CMD[@]}" "${COMPOSE_FILES[@]}" "${profiles[@]}" up -d
