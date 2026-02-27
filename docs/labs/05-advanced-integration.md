# Lab 02-05 — Advanced Integration

**Module:** 02 — Keycloak OAuth2/OIDC/SAML SSO provider  
**Duration:** See [lab manual](https://github.com/it-stack-dev/it-stack-docs)  
**Test Script:** 	ests/labs/test-lab-02-05.sh  
**Compose File:** docker/docker-compose.integration.yml

## Objective

Connect keycloak to the full IT-Stack ecosystem (FreeIPA, Traefik, Graylog, Zabbix).

## Prerequisites

- Labs 02-01 through 02-04 pass
- Prerequisite services running

## Steps

### 1. Prepare Environment

```bash
cd it-stack-keycloak
cp .env.example .env  # edit as needed
```

### 2. Start Services

```bash
make test-lab-05
```

Or manually:

```bash
docker compose -f docker/docker-compose.integration.yml up -d
```

### 3. Verify

```bash
docker compose ps
curl -sf http://localhost:8080/health
```

### 4. Run Test Suite

```bash
bash tests/labs/test-lab-02-05.sh
```

## Expected Results

All tests pass with FAIL: 0.

## Cleanup

```bash
docker compose -f docker/docker-compose.integration.yml down -v
```

## Troubleshooting

See [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) for common issues.
