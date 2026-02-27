#!/bin/bash
# entrypoint.sh — IT-Stack keycloak container entrypoint
set -euo pipefail

echo "Starting IT-Stack KEYCLOAK (Module 02)..."

# Source any environment overrides
if [ -f /opt/it-stack/keycloak/config.env ]; then
    # shellcheck source=/dev/null
    source /opt/it-stack/keycloak/config.env
fi

# Execute the upstream entrypoint or command
exec "$$@"
