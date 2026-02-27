# Dockerfile — IT-Stack KEYCLOAK wrapper
# Module 02 | Category: identity | Phase: 1
# Base image: quay.io/keycloak/keycloak:24

FROM quay.io/keycloak/keycloak:24

# Labels
LABEL org.opencontainers.image.title="it-stack-keycloak" \
      org.opencontainers.image.description="Keycloak OAuth2/OIDC/SAML SSO provider" \
      org.opencontainers.image.vendor="it-stack-dev" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="https://github.com/it-stack-dev/it-stack-keycloak"

# Copy custom configuration and scripts
COPY src/ /opt/it-stack/keycloak/
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
