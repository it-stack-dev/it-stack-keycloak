# Architecture — IT-Stack KEYCLOAK

## Overview

Keycloak is the central SSO broker for all IT-Stack services, federating users from FreeIPA via LDAP.

## Role in IT-Stack

- **Category:** identity
- **Phase:** 1
- **Server:** lab-id1 (10.0.50.11)
- **Ports:** 8080 (HTTP), 8443 (HTTPS)

## Dependencies

| Dependency | Type | Required For |
|-----------|------|--------------|
| FreeIPA | Identity | User directory |
| Keycloak | SSO | Authentication |
| PostgreSQL | Database | Data persistence |
| Redis | Cache | Sessions/queues |
| Traefik | Proxy | HTTPS routing |

## Data Flow

```
User → Traefik (HTTPS) → keycloak → PostgreSQL (data)
                       ↗ Keycloak (auth)
                       ↗ Redis (sessions)
```

## Security

- All traffic over TLS via Traefik
- Authentication delegated to Keycloak OIDC
- Database credentials via Ansible Vault
- Logs shipped to Graylog
