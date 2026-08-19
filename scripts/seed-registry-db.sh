#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/registry-variant.sh"

VARIANT="${VARIANT:-${1:-}}"
registry_variant_validate "$VARIANT"

registry_variant_paths "$VARIANT"
registry_variant_db_settings "$VARIANT"
registry_variant_export_psql

LOAD_SAMPLE_DATA="${LOAD_SAMPLE_DATA:-false}"
LOAD_GEO_DATA="${LOAD_GEO_DATA:-false}"
LOAD_IMAGES="${LOAD_IMAGES:-false}"
LOAD_TEMPLATES="${LOAD_TEMPLATES:-false}"

if [[ ! -d "$EXTENSION_DIR" ]]; then
  echo "Extension not found at ${EXTENSION_DIR}. Run: make clone" >&2
  exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "psql is required for registry seeding. Install PostgreSQL client tools." >&2
  exit 1
fi

echo "============================================="
echo " Seeding ${LABEL}"
echo " Database   : ${REGISTRY_DB_NAME}@${PGHOST}:${PGPORT}"
echo " Sample data: ${LOAD_SAMPLE_DATA}"
echo " Geo data   : ${LOAD_GEO_DATA}"
echo "============================================="

registry_variant_run_sql_tree "$META_DATA_DIR" "configuration SQL"
registry_variant_seed_awe_meta_data "$VARIANT"

if [[ "$LOAD_SAMPLE_DATA" == "true" && "$LOAD_GEO_DATA" != "true" ]]; then
  LOAD_GEO_DATA=true
  echo "[seed] Enabling geo data because sample data was requested."
fi

case "$VARIANT" in
  farmer-registry)
    if [[ "$LOAD_GEO_DATA" == "true" || "$LOAD_SAMPLE_DATA" == "true" ]]; then
      OPENG2P_DATA_DIR="$(registry_variant_open_data_dir)"
      if [[ ! -d "$OPENG2P_DATA_DIR" ]]; then
        echo "openg2p-data not found at ${OPENG2P_DATA_DIR}. Run: make clone" >&2
        exit 1
      fi
    fi

    if [[ "$LOAD_GEO_DATA" == "true" ]]; then
      echo "[seed] Seeding Master Data geo/codelists for ${LABEL} ..."
      VARIANT="$VARIANT" bash "${ROOT_DIR}/scripts/seed-master-data.sh" "$VARIANT"
    else
      echo "[seed] Skipping geo data (LOAD_GEO_DATA=${LOAD_GEO_DATA})."
    fi

    if [[ "$LOAD_SAMPLE_DATA" == "true" ]]; then
      FARMER_SEED_DATA_DIR="${FARMER_SEED_DATA_DIR:-${DB_SEED_DIR}/seed-data}"
      if [[ ! -f "${DB_SEED_DIR}/load_sample_data.py" ]]; then
        echo "Farmer sample loader not found at ${DB_SEED_DIR}/load_sample_data.py." >&2
        exit 1
      fi

      echo "[seed] Preparing demography CSVs for farmer sample load ..."
      python3 "${ROOT_DIR}/scripts/openg2p-data-demography-to-farmer-csv.py" "$OPENG2P_DATA_DIR"

      SOURCE_FARMER_SEED_DATA_DIR="${FARMER_SEED_DATA_DIR:-${DB_SEED_DIR}/seed-data}"
      FARMER_SEED_DATA_DIR="${ROOT_DIR}/generated/farmer-registry/seed-data-remapped"
      echo "[seed] Remapping farmer seed JSON ids to openg2p-data demography ids ..."
      python3 "${ROOT_DIR}/scripts/openg2p-data-remap-farmer-seed-data.py" \
        "$OPENG2P_DATA_DIR" "$SOURCE_FARMER_SEED_DATA_DIR" "$FARMER_SEED_DATA_DIR"

      echo "[seed] Clearing existing farmer sample data ..."
      registry_variant_clear_sample_data "$VARIANT"

      echo "[seed] Loading farmer sample data via ${DB_SEED_DIR}/load_sample_data.py ..."
      export OPENG2P_DATA_DIR FARMER_SEED_DATA_DIR
      registry_variant_export_psql
      registry_variant_export_master_psql
      registry_variant_run_db_seed_python load_sample_data.py

      echo "[seed] Normalizing farmer enum values to match extension schemas ..."
      registry_variant_ensure_db_seed_venv
      registry_variant_export_psql
      (
        # shellcheck disable=SC1091
        source "${DB_SEED_DIR}/venv/bin/activate"
        python3 "${ROOT_DIR}/scripts/fix-farmer-registry-seeded-enums.py"
        python3 "${ROOT_DIR}/scripts/seed-farmer-registry-initial-history.py"
      )

      echo "[seed] Validating farmer seed data against extension schemas ..."
      bash "${ROOT_DIR}/scripts/validate-farmer-registry-seed.sh"
    else
      echo "[seed] Skipping farmer sample data (LOAD_SAMPLE_DATA=${LOAD_SAMPLE_DATA})."
    fi
    ;;
  national-social-registry)
    if [[ "$LOAD_GEO_DATA" == "true" || "$LOAD_SAMPLE_DATA" == "true" ]]; then
      OPENG2P_DATA_DIR="$(registry_variant_open_data_dir)"
      if [[ ! -d "$OPENG2P_DATA_DIR" ]]; then
        echo "openg2p-data not found at ${OPENG2P_DATA_DIR}. Run: make clone" >&2
        exit 1
      fi
    fi

    if [[ "$LOAD_GEO_DATA" == "true" ]]; then
      echo "[seed] Seeding Master Data geo/codelists for ${LABEL} ..."
      VARIANT="$VARIANT" bash "${ROOT_DIR}/scripts/seed-master-data.sh" "$VARIANT"
    else
      echo "[seed] Skipping geo data (LOAD_GEO_DATA=${LOAD_GEO_DATA})."
    fi

    if [[ "$LOAD_SAMPLE_DATA" == "true" || "$LOAD_TEMPLATES" == "true" || "$LOAD_IMAGES" == "true" ]]; then
      if [[ ! -x "${DB_SEED_DIR}/venv/bin/python" ]]; then
        echo "[seed] Installing db-seed Python dependencies ..."
        VARIANT=national-social-registry bash "${ROOT_DIR}/scripts/install-registry-db-seed.sh"
      fi
    fi

    if [[ "$LOAD_SAMPLE_DATA" == "true" ]]; then
      NSR_SEED_DATA_DIR="${NSR_SEED_DATA_DIR:-${DB_SEED_DIR}/seed-data}"
      LOAD_SCRIPT="${DB_SEED_DIR}/load_sample_data.py"

      if [[ ! -f "$LOAD_SCRIPT" ]]; then
        echo "NSR sample loader not found at ${LOAD_SCRIPT}. Run: make clone" >&2
        exit 1
      fi

      echo "[seed] Preparing demography CSVs from openg2p-data JSON (if needed) ..."
      python3 "${ROOT_DIR}/scripts/openg2p-data-demography-to-csv.py" "$OPENG2P_DATA_DIR"

      echo "[seed] Clearing existing NSR sample data ..."
      registry_variant_clear_sample_data "$VARIANT"

      echo "[seed] Loading NSR sample data via ${LOAD_SCRIPT} ..."
      (
        cd "$DB_SEED_DIR"
        # shellcheck disable=SC1091
        source "${API_DIR}/venv/bin/activate"
        export OPENG2P_DATA_DIR NSR_SEED_DATA_DIR
        registry_variant_export_psql
        registry_variant_export_master_psql
        python3 load_sample_data.py
      )
    else
      echo "[seed] Skipping NSR sample data (LOAD_SAMPLE_DATA=${LOAD_SAMPLE_DATA})."
    fi

    if [[ "$LOAD_TEMPLATES" == "true" && -f "${DB_SEED_DIR}/upload_templates.py" ]]; then
      echo "[seed] Uploading NSR templates to MinIO ..."
      (
        cd "$DB_SEED_DIR"
        # shellcheck disable=SC1091
        source venv/bin/activate
        export MINIO_ENDPOINT="${MINIO_ENDPOINT:-localhost:9000}"
        export MINIO_ACCESS_KEY="${MINIO_ROOT_USER:-admin}"
        export MINIO_SECRET_KEY="${MINIO_ROOT_PASSWORD:-secret}"
        export MINIO_SECURE="${MINIO_SECURE:-false}"
        export TEMPLATE_BUCKET_NAME="${REGISTRY_TEMPLATE_BUCKET:-templates}"
        python3 upload_templates.py
      )
    fi

    if [[ "$LOAD_IMAGES" == "true" && -f "${DB_SEED_DIR}/upload_images.py" ]]; then
      echo "[seed] Uploading NSR profile images to MinIO ..."
      (
        cd "$DB_SEED_DIR"
        # shellcheck disable=SC1091
        source venv/bin/activate
        export OPENG2P_DATA_DIR="$(registry_variant_open_data_dir)"
        export MINIO_ENDPOINT="${MINIO_ENDPOINT:-localhost:9000}"
        export MINIO_ACCESS_KEY="${MINIO_ROOT_USER:-admin}"
        export MINIO_SECRET_KEY="${MINIO_ROOT_PASSWORD:-secret}"
        export MINIO_SECURE="${MINIO_SECURE:-false}"
        export IMAGE_BUCKET_NAME="${REGISTRY_IMAGE_BUCKET:-registrant-photos}"
        python3 upload_images.py
      )
    fi
    ;;
  village-social-security-registry)
    if [[ "$LOAD_GEO_DATA" == "true" || "$LOAD_SAMPLE_DATA" == "true" ]]; then
      OPENG2P_DATA_DIR="$(registry_variant_open_data_dir)"
      if [[ ! -d "$OPENG2P_DATA_DIR" ]]; then
        echo "openg2p-data not found at ${OPENG2P_DATA_DIR}. Run: make clone PROFILE=vsss" >&2
        exit 1
      fi
    fi

    if [[ "$LOAD_GEO_DATA" == "true" ]]; then
      echo "[seed] Seeding Master Data geo/codelists for ${LABEL} ..."
      VARIANT="$VARIANT" bash "${ROOT_DIR}/scripts/seed-master-data.sh" "$VARIANT"
      if [[ -f "${DB_SEED_DIR}/load_geo_data.py" ]]; then
        echo "[seed] Loading VSSS geo into master data via ${DB_SEED_DIR}/load_geo_data.py ..."
        (
          cd "$DB_SEED_DIR"
          # shellcheck disable=SC1091
          source venv/bin/activate
          export OPENG2P_DATA_DIR
          registry_variant_export_master_psql
          python3 load_geo_data.py
        )
      fi
    else
      echo "[seed] Skipping geo data (LOAD_GEO_DATA=${LOAD_GEO_DATA})."
    fi

    if [[ "$LOAD_SAMPLE_DATA" == "true" || "$LOAD_TEMPLATES" == "true" || "$LOAD_IMAGES" == "true" ]]; then
      if [[ ! -x "${DB_SEED_DIR}/venv/bin/python" ]]; then
        echo "[seed] Installing db-seed Python dependencies ..."
        VARIANT=village-social-security-registry bash "${ROOT_DIR}/scripts/install-registry-db-seed.sh"
      fi
    fi

    if [[ "$LOAD_SAMPLE_DATA" == "true" ]]; then
      LOAD_SCRIPT="${DB_SEED_DIR}/load_sample_data.py"
      if [[ ! -f "$LOAD_SCRIPT" ]]; then
        echo "VSSS sample loader not found at ${LOAD_SCRIPT}. Run: make clone PROFILE=vsss" >&2
        exit 1
      fi

      echo "[seed] Clearing existing VSSS sample data ..."
      registry_variant_clear_sample_data "$VARIANT"

      echo "[seed] Loading VSSS sample register data via ${LOAD_SCRIPT} ..."
      (
        cd "$DB_SEED_DIR"
        # shellcheck disable=SC1091
        source venv/bin/activate
        export OPENG2P_DATA_DIR
        registry_variant_export_psql
        registry_variant_export_master_psql
        python3 load_sample_data.py
      )
    else
      echo "[seed] Skipping VSSS sample data (LOAD_SAMPLE_DATA=${LOAD_SAMPLE_DATA})."
    fi

    if [[ "$LOAD_TEMPLATES" == "true" && -f "${DB_SEED_DIR}/upload_templates.py" ]]; then
      echo "[seed] Uploading VSSS templates to MinIO ..."
      (
        cd "$DB_SEED_DIR"
        # shellcheck disable=SC1091
        source venv/bin/activate
        export MINIO_ENDPOINT="${MINIO_ENDPOINT:-localhost:9000}"
        export MINIO_ACCESS_KEY="${MINIO_ROOT_USER:-admin}"
        export MINIO_SECRET_KEY="${MINIO_ROOT_PASSWORD:-secret}"
        export MINIO_SECURE="${MINIO_SECURE:-false}"
        export TEMPLATE_BUCKET_NAME="${REGISTRY_TEMPLATE_BUCKET:-templates}"
        python3 upload_templates.py
      )
    fi

    if [[ "$LOAD_IMAGES" == "true" && -f "${DB_SEED_DIR}/upload_images.py" ]]; then
      echo "[seed] Uploading VSSS profile images to MinIO ..."
      (
        cd "$DB_SEED_DIR"
        # shellcheck disable=SC1091
        source venv/bin/activate
        export OPENG2P_DATA_DIR="$(registry_variant_open_data_dir)"
        export MINIO_ENDPOINT="${MINIO_ENDPOINT:-localhost:9000}"
        export MINIO_ACCESS_KEY="${MINIO_ROOT_USER:-admin}"
        export MINIO_SECRET_KEY="${MINIO_ROOT_PASSWORD:-secret}"
        export MINIO_SECURE="${MINIO_SECURE:-false}"
        export IMAGE_BUCKET_NAME="${REGISTRY_IMAGE_BUCKET:-registrant-photos}"
        python3 upload_images.py
      )
    fi
    ;;
  *)
    if [[ "$LOAD_SAMPLE_DATA" == "true" ]]; then
      registry_variant_run_sql_tree "$SAMPLE_DATA_DIR" "sample data SQL"
    else
      echo "[seed] Skipping sample data (LOAD_SAMPLE_DATA=${LOAD_SAMPLE_DATA})."
    fi
    ;;
esac

echo "[seed] Done for ${LABEL}."
