awe:
  service_id: openg2p.awe
  api_version: "1.0"
  module: registry

  webhook:
    timeout_seconds: 10
    max_attempts: 6
    backoff_seconds: [60, 300, 900, 3600, 21600]
    poll_interval_seconds: 2
    batch_size: 20

  resolver:
    http_timeout_seconds: 5

  sla:
    check_interval_seconds: 300

  keycloak:
    # Docker: KEYCLOAK_INTERNAL_URL is http://keycloak:PORT (admin + JWKS).
    # Native generate passes KEYCLOAK_URL for both (localhost).
    base_url: "{{KEYCLOAK_INTERNAL_URL}}"
    realm: "{{KEYCLOAK_REALM}}"
    admin_client_id: awe-admin-resolver
    admin_client_secret: "{{KEYCLOAK_AWE_RESOLVER_CLIENT_SECRET}}"
    issuer: "{{KEYCLOAK_URL}}/realms/{{KEYCLOAK_REALM}}"
    jwks_url: "{{KEYCLOAK_INTERNAL_URL}}/realms/{{KEYCLOAK_REALM}}/protocol/openid-connect/certs"
    audience: ""

  notifier:
    enabled: false
