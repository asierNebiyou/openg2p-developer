#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/extension-manifest.sh"
source "${ROOT_DIR}/scripts/lib/registry-variant.sh"

VARIANT="${1:-}"
if [[ -z "$VARIANT" ]]; then
  echo "Usage: postgres-ensure-extension-databases.sh <variant>" >&2
  exit 1
fi

registry_variant_validate "$VARIANT"
registry_variant_load_env

if registry_variant_is_custom "$VARIANT"; then
  extension_manifest_load "$VARIANT"
  REGISTRY_DB="${EXTENSION_REGISTRY_DB}"
  MASTER_DB="${EXTENSION_MASTER_DATA_DB}"
else
  registry_variant_db_settings "$VARIANT"
  REGISTRY_DB="${REGISTRY_DB_NAME}"
  MASTER_DB="${MASTER_DATA_DB_NAME}"
fi

POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_SUPERUSER="${POSTGRES_SUPERUSER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"

if ! command -v psql >/dev/null 2>&1; then
  echo "psql is required. Install PostgreSQL client tools." >&2
  exit 1
fi

export PGHOST="$POSTGRES_HOST"
export PGPORT="$POSTGRES_PORT"
export PGUSER="$POSTGRES_SUPERUSER"
export PGPASSWORD="$POSTGRES_PASSWORD"

ensure_db() {
  local db_name="$1"
  local exists
  exists="$(psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${db_name}'" 2>/dev/null || true)"
  if [[ "$exists" == "1" ]]; then
    echo "[postgres] Database ${db_name} already exists"
    return 0
  fi
  echo "[postgres] Creating database ${db_name} ..."
  psql -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"${db_name}\" OWNER postgres;"
}

ensure_db "$REGISTRY_DB"
ensure_db "$MASTER_DB"

# Shared infra DBs (Postgres volume may predate docker init script entries).
for shared_db in iam_staff awe idgenerator; do
  ensure_db "$shared_db"
done

echo "[postgres] Ensuring pg_trgm on ${REGISTRY_DB} ..."
psql -d "$REGISTRY_DB" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"

echo "[postgres] Registry databases ready for ${VARIANT}."
