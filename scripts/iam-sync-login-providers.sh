#!/usr/bin/env bash
# Push generated login_providers.json URLs into iam_staff.login_providers.
# IAM seed_if_empty never updates existing rows, so a later generate (port
# changes, 127.0.0.1 metadata URL) would otherwise leave a stale IdP URL and
# /auth/start_authentication_transaction returns G2P-REQ-100.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_SUPERUSER="${POSTGRES_SUPERUSER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
JSON_FILE="${ROOT_DIR}/generated/iam/data/login_providers.json"

if [[ ! -f "${JSON_FILE}" ]]; then
  echo "Missing ${JSON_FILE}. Run: make generate" >&2
  exit 1
fi

python3 - "${JSON_FILE}" "${POSTGRES_HOST}" "${POSTGRES_PORT}" "${POSTGRES_SUPERUSER}" "${POSTGRES_PASSWORD}" <<'PY'
import json
import os
import subprocess
import sys

json_file, host, port, user, password = sys.argv[1:6]
rows = json.loads(open(json_file, encoding="utf-8").read())
if not rows:
    raise SystemExit("login_providers.json is empty")

def lit(value):
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return str(value)
    text = json.dumps(value) if isinstance(value, (list, dict)) else str(value)
    return "'" + text.replace("'", "''") + "'"

statements = []
for row in rows:
    provider_id = int(row["id"])
    statements.append(
        "UPDATE login_providers SET "
        f"server_metadata_url = {lit(row.get('server_metadata_url'))}, "
        f"authorization_endpoint = {lit(row.get('authorization_endpoint'))}, "
        f"token_endpoint = {lit(row.get('token_endpoint'))}, "
        f"userinfo_endpoint = {lit(row.get('userinfo_endpoint'))}, "
        f"jwks_uri = {lit(row.get('jwks_uri'))}, "
        f"issuer = {lit(row['issuer'])}, "
        f"oauth_callback_url = {lit(row['oauth_callback_url'])}, "
        f"default_redirect_uri = {lit(row.get('default_redirect_uri'))}, "
        f"client_secret = {lit(row.get('client_secret'))} "
        f"WHERE id = {provider_id};"
        f"SELECT id, server_metadata_url, authorization_endpoint, token_endpoint, "
        f"userinfo_endpoint, jwks_uri, issuer, oauth_callback_url "
        f"FROM login_providers WHERE id = {provider_id};"
    )
sql = "\n".join(statements)
env = os.environ.copy()
env["PGPASSWORD"] = password
proc = subprocess.run(
    [
        "psql",
        "-h", host,
        "-p", str(port),
        "-U", user,
        "-d", "iam_staff",
        "-v", "ON_ERROR_STOP=1",
        "-c", sql,
    ],
    env=env,
    check=False,
)
raise SystemExit(proc.returncode)
PY
