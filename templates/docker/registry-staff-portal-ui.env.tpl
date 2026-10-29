PORT=3000
# Server-side Next.js fetches (inside the UI container) — use Compose DNS, not host localhost.
BACKEND_API_URL="http://{{REGISTRY_STAFF_API_SERVICE}}:8000"
MASTERDATA_BACKEND_API_URL="http://{{REGISTRY_MASTER_DATA_API_SERVICE}}:8000"
DEFAULT_LOCALE="en"
PARTNER_IMPORT_EXPORT_ENABLE="true"
PAGE_SIZE=10

# Server-side Next.js /api/login fetches IAM on the Compose network (localhost:port
# from inside the UI container times out / refuses even with host-gateway).
IAM_URL="http://iam-staff-api:8000"
# Browser-facing logout URL (opened in the user's browser, not from the container).
KEYCLOAK_LOGOUT_URL="{{KEYCLOAK_URL}}/realms/staff/protocol/openid-connect/logout"
LOGIN_PROVIDER_ID="1"
APPLICATION_MNEMONIC="{{REGISTRY_UI_APP_MNEMONIC}}"
COOKIE_DOMAIN="localhost"
REDIRECT_URL="http://localhost:{{REGISTRY_UI_PORT}}"
