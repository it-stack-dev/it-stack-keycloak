#!/usr/bin/env bash
# test-lab-02-01.sh — Lab 02-01: Standalone
# Module 02: Keycloak OAuth2/OIDC/SAML SSO provider
# Basic keycloak functionality in complete isolation
set -euo pipefail

LAB_ID="02-01"
LAB_NAME="Standalone"
MODULE="keycloak"
COMPOSE_FILE="docker/docker-compose.standalone.yml"
PASS=0
FAIL=0

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN} Lab ${LAB_ID}: ${LAB_NAME}${NC}"
echo -e "${CYAN} Module: ${MODULE}${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""

# ── Helpers ───────────────────────────────────────────────────────────────────
KC_URL=http://localhost:8080
KC_ADMIN=admin
KC_ADMIN_PASS="Lab01Password!"
KC_REALM=it-stack-lab

kc_get_token() {
  curl -sf -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "grant_type=password&client_id=admin-cli&username=${KC_ADMIN}&password=${KC_ADMIN_PASS}" \
    2>/dev/null | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
}

kc_api() {
  local method="${1:-GET}" path="$2" data="${3:-}"
  local token
  token=$(kc_get_token)
  if [[ -n "${data}" ]]; then
    curl -sf -X "${method}" "${KC_URL}/admin/realms${path}" \
      -H "Authorization: Bearer ${token}" \
      -H 'Content-Type: application/json' \
      -d "${data}" 2>/dev/null
  else
    curl -sf -X "${method}" "${KC_URL}/admin/realms${path}" \
      -H "Authorization: Bearer ${token}" 2>/dev/null
  fi
}

wait_for_keycloak() {
  local retries=40
  until curl -sf "${KC_URL}/health/ready" > /dev/null 2>&1; do
    retries=$((retries - 1))
    if [[ "${retries}" -le 0 ]]; then
      fail "Keycloak did not become ready within 200 seconds"
      return 1
    fi
    info "Waiting for Keycloak... (${retries} retries left)"
    sleep 5
  done
  pass "Keycloak is ready"
}

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
info "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" pull --quiet 2>/dev/null || true
docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans
info "Waiting for Keycloak to initialize (this takes ~90 seconds in dev mode)..."
wait_for_keycloak

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
info "Phase 2: Health Checks"

if docker compose -f "${COMPOSE_FILE}" ps keycloak | grep -qE "running|Up|healthy"; then
  pass "Keycloak container is running"
else
  fail "Keycloak container is not running"
fi

if nc -z -w3 localhost 8080 2>/dev/null; then
  pass "Port 8080 is open"
else
  fail "Port 8080 is not reachable"
fi

# Health endpoints
if curl -sf "${KC_URL}/health/ready" > /dev/null 2>&1; then
  pass "/health/ready returns 200"
else
  fail "/health/ready not accessible"
fi

if curl -sf "${KC_URL}/health/live" > /dev/null 2>&1; then
  pass "/health/live returns 200"
else
  fail "/health/live not accessible"
fi

# Metrics endpoint
if curl -sf "${KC_URL}/metrics" | grep -q "keycloak"; then
  pass "/metrics endpoint is enabled and returns Keycloak metrics"
else
  warn "/metrics endpoint may not be fully populated yet"
fi

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
info "Phase 3: Functional Tests"

# 3.1 Admin authentication
info "3.1 — Admin authentication"
ADMIN_TOKEN=$(kc_get_token)
if [[ -n "${ADMIN_TOKEN}" ]]; then
  pass "Admin token obtained via password grant"
else
  fail "Could not obtain admin token — check admin credentials"
fi

# 3.2 OIDC well-known (master realm)
info "3.2 — OIDC well-known endpoint"
if curl -sf "${KC_URL}/realms/master/.well-known/openid-configuration" \
    | grep -q '"issuer"'; then
  pass "OIDC well-known endpoint accessible for master realm"
else
  fail "OIDC well-known endpoint not accessible"
fi

# 3.3 Admin API - list realms
info "3.3 — Admin API access"
REALMS=$(curl -sf "${KC_URL}/admin/realms" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null)
if echo "${REALMS}" | grep -q '"realm"'; then
  pass "Admin API /admin/realms returns realm list"
else
  fail "Admin API /admin/realms did not return expected data"
fi

# Verify master realm exists
if echo "${REALMS}" | grep -q '"master"'; then
  pass "Master realm exists in realm list"
else
  fail "Master realm not found in realm list"
fi

# 3.4 Create test realm
info "3.4 — Create test realm"
CREATE_STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
  -X POST "${KC_URL}/admin/realms" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "{ \"realm\": \"${KC_REALM}\", \"enabled\": true, \"displayName\": \"IT-Stack Lab 01\" }" \
  2>/dev/null)
if [[ "${CREATE_STATUS}" == "201" ]]; then
  pass "Test realm '${KC_REALM}' created (HTTP 201)"
elif [[ "${CREATE_STATUS}" == "409" ]]; then
  warn "Test realm already exists (HTTP 409) — continuing"
else
  fail "Realm creation returned HTTP ${CREATE_STATUS}"
fi

# 3.5 Verify created realm
info "3.5 — Verify created realm"
if curl -sf "${KC_URL}/realms/${KC_REALM}/.well-known/openid-configuration" \
    | grep -q '"issuer"'; then
  pass "Created realm '${KC_REALM}' has working OIDC endpoint"
else
  fail "Created realm '${KC_REALM}' OIDC endpoint not working"
fi

# 3.6 Create test user in realm
info "3.6 — Create test user"
# Refresh token for the new realm operations
ADMIN_TOKEN=$(kc_get_token)
USER_STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
  -X POST "${KC_URL}/admin/realms/${KC_REALM}/users" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{
    "username": "lab01user",
    "email": "lab01user@lab.local",
    "firstName": "Lab",
    "lastName": "User",
    "enabled": true,
    "credentials": [{"type": "password", "value": "UserPass123!", "temporary": false}]
  }' 2>/dev/null)
if [[ "${USER_STATUS}" == "201" ]]; then
  pass "Test user 'lab01user' created in realm (HTTP 201)"
elif [[ "${USER_STATUS}" == "409" ]]; then
  warn "Test user already exists (HTTP 409)"
else
  fail "User creation returned HTTP ${USER_STATUS}"
fi

# 3.7 Verify user exists via search
info "3.7 — Verify user via admin search"
ADMIN_TOKEN=$(kc_get_token)
USERS=$(curl -sf "${KC_URL}/admin/realms/${KC_REALM}/users?search=lab01user" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null)
if echo "${USERS}" | grep -q 'lab01user'; then
  pass "User 'lab01user' found via admin search API"
else
  fail "User 'lab01user' not found via admin search"
fi

# 3.8 Create OIDC client
info "3.8 — Create OIDC client"
ADMIN_TOKEN=$(kc_get_token)
CLIENT_STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
  -X POST "${KC_URL}/admin/realms/${KC_REALM}/clients" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{
    "clientId": "lab01-app",
    "enabled": true,
    "protocol": "openid-connect",
    "publicClient": true,
    "redirectUris": ["http://localhost:3000/*"],
    "webOrigins": ["http://localhost:3000"]
  }' 2>/dev/null)
if [[ "${CLIENT_STATUS}" == "201" ]]; then
  pass "OIDC client 'lab01-app' created (HTTP 201)"
elif [[ "${CLIENT_STATUS}" == "409" ]]; then
  warn "OIDC client already exists (HTTP 409)"
else
  fail "Client creation returned HTTP ${CLIENT_STATUS}"
fi

# 3.9 Token introspection endpoint available
info "3.9 — Token endpoints"
TOKEN_EP=$(curl -sf "${KC_URL}/realms/${KC_REALM}/.well-known/openid-configuration" \
  2>/dev/null | grep -o '"token_endpoint":"[^"]*"' | cut -d'"' -f4)
if [[ -n "${TOKEN_EP}" ]]; then
  pass "Token endpoint discovered: ${TOKEN_EP}"
else
  fail "Token endpoint not found in OIDC discovery"
fi

# 3.10 Cleanup: delete test realm
info "3.10 — Cleanup test realm"
ADMIN_TOKEN=$(kc_get_token)
DEL_STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
  -X DELETE "${KC_URL}/admin/realms/${KC_REALM}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null)
if [[ "${DEL_STATUS}" == "204" ]]; then
  pass "Test realm '${KC_REALM}' deleted cleanly (HTTP 204)"
else
  warn "Realm deletion returned HTTP ${DEL_STATUS}"
fi

# ── PHASE 4: Cleanup ──────────────────────────────────────────────────────────
info "Phase 4: Cleanup"
docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
info "Cleanup complete"

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
