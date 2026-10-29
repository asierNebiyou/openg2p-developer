[
  {
    "id": 1,
    "provider_name": "Keycloak Staff",
    "description": "Local Keycloak staff realm",
    "client_id": "iam-staff-portal",
    "client_secret": "{{KEYCLOAK_IAM_CLIENT_SECRET}}",
    "token_endpoint_auth_method": "client_secret_post",
    "server_metadata_url": "{{KEYCLOAK_METADATA_URL}}/realms/staff/.well-known/openid-configuration",
    "issuer": "{{KEYCLOAK_URL}}/realms/staff",
    "oauth_callback_url": "http://localhost:{{IAM_STAFF_PORT}}/auth/callback",
    "default_redirect_uri": "http://localhost:{{STAFF_PORTAL_UI_PORT}}/",
    "scope": "openid profile email",
    "enable_pkce": true,
    "active": true,
    "audiences": {{REGISTRY_OIDC_AUDIENCES}},
    "adapter_name": "keycloak"
  }
]
