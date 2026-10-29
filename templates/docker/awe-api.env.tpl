# Docker AWE API runtime env
UVICORN_HOST="0.0.0.0"
UVICORN_PORT=8000

DB_HOST="postgres"
DB_PORT=5432
DB_NAME=awe
DB_USER=postgres
DB_PASSWORD="{{POSTGRES_PASSWORD}}"

CONFIG_PATH="/app/config/default.yaml"

# Tokens advertise issuer localhost (KC_HOSTNAME). Fetch JWKS / admin API via
# Compose DNS — localhost:8080 inside this container is not Keycloak.
AWE__KEYCLOAK__BASE_URL="{{KEYCLOAK_INTERNAL_URL}}"
AWE__KEYCLOAK__REALM="{{KEYCLOAK_REALM}}"
AWE__KEYCLOAK__ADMIN_CLIENT_ID=awe-admin-resolver
AWE__KEYCLOAK__ADMIN_CLIENT_SECRET="{{KEYCLOAK_AWE_RESOLVER_CLIENT_SECRET}}"
AWE__KEYCLOAK__ISSUER="{{KEYCLOAK_URL}}/realms/{{KEYCLOAK_REALM}}"
AWE__KEYCLOAK__JWKS_URL="{{KEYCLOAK_INTERNAL_URL}}/realms/{{KEYCLOAK_REALM}}/protocol/openid-connect/certs"
AWE__KEYCLOAK__AUDIENCE=""
