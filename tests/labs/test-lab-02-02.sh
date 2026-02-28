#!/usr/bin/env bash
# test-lab-02-02.sh — Lab 02-02: External Dependencies
# Module 02: Keycloak — External PostgreSQL database
set -euo pipefail

LAB_ID="02-02"
LAB_NAME="External PostgreSQL"
COMPOSE_FILE="docker/docker-compose.lan.yml"
KC_URL="${KC_URL:-http://localhost:8080}"
KC_ADMIN="${KC_ADMIN:-admin}"
KC_PASS="${KC_PASS:-Lab02Password!}"
KC_REALM="${KC_REALM:-it-stack-lab}"
PASS=0; FAIL=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

pass()   { echo -e "${GREEN}[PASS]${NC} $1"; ((++PASS)); }
fail()   { echo -e "${RED}[FAIL]${NC} $1"; ((++FAIL)); }
info()   { echo -e "${CYAN}[INFO]${NC} $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
header() { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}"; }

kc_token() {
  curl -sf --max-time 10 \
    -d "client_id=admin-cli" \
    -d "username=${KC_ADMIN}" \
    -d "password=${KC_PASS}" \
    -d "grant_type=password" \
    "${KC_URL}/realms/master/protocol/openid-connect/token" \
    | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
}

kc_api() {
  local path="$1"; local token="$2"
  curl -sf --max-time 10 \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    "${KC_URL}/admin/realms${path}"
}

echo -e "\n${BOLD}IT-Stack Lab ${LAB_ID} — ${LAB_NAME}${NC}"
echo -e "Module 02: Keycloak | $(date '+%Y-%m-%d %H:%M:%S')\n"

header "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" pull --quiet 2>/dev/null || true
docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans
info "Waiting for Keycloak /health/ready (up to 200s)..."
timeout 200 bash -c "until curl -sf ${KC_URL}/health/ready > /dev/null 2>&1; do sleep 5; done"
pass "Keycloak ready"

header "Phase 2: Health Endpoints"
for path in "/health/ready" "/health/live"; do
  CODE=$(curl -so /dev/null -w "%{http_code}" --max-time 5 "${KC_URL}${path}" 2>/dev/null || echo "000")
  if [ "${CODE}" = "200" ]; then
    pass "${path} → HTTP ${CODE}"
  else
    fail "${path} → HTTP ${CODE}"
  fi
done

header "Phase 3: External PostgreSQL Connectivity"
# Verify DB container is healthy
DB_STATUS=$(docker compose -f "${COMPOSE_FILE}" ps keycloak-db 2>/dev/null | grep -c "healthy\|Up" || echo "0")
if [ "${DB_STATUS}" -ge 1 ] 2>/dev/null; then
  pass "External PostgreSQL container healthy"
else
  warn "PostgreSQL container status unclear"
fi

# Keycloak started and can serve tokens = JDBC connection succeeded
TOKEN=$(kc_token 2>/dev/null || echo "")
if [ -n "${TOKEN}" ]; then
  pass "Admin token obtained (Keycloak ↔ PostgreSQL connection verified)"
else
  fail "Failed to obtain admin token — Keycloak may not have connected to PostgreSQL"
fi

header "Phase 4: Realm CRUD"
[ -n "${TOKEN:-}" ] || TOKEN=$(kc_token)

CREATE_CODE=$(curl -so /dev/null -w "%{http_code}" --max-time 10 \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"realm\":\"${KC_REALM}\",\"enabled\":true}" \
  "${KC_URL}/admin/realms" 2>/dev/null || echo "000")
if [ "${CREATE_CODE}" = "201" ]; then
  pass "Realm '${KC_REALM}' created (HTTP 201)"
elif [ "${CREATE_CODE}" = "409" ]; then
  pass "Realm '${KC_REALM}' already exists (HTTP 409)"
else
  fail "Realm creation returned HTTP ${CREATE_CODE}"
fi

REALM_CHECK=$(kc_api "/${KC_REALM}" "${TOKEN}" 2>/dev/null | grep -o '"realm":"[^"]*"' | head -1 || echo "")
if [ -n "${REALM_CHECK}" ]; then
  pass "Realm '${KC_REALM}' readable via Admin API: ${REALM_CHECK}"
else
  fail "Realm '${KC_REALM}' not readable"
fi

header "Phase 5: Persistence Across Restart"
# Stop and restart Keycloak only (DB keeps running)
info "Restarting Keycloak container..."
docker compose -f "${COMPOSE_FILE}" restart keycloak
info "Waiting for Keycloak to come back up..."
timeout 200 bash -c "until curl -sf ${KC_URL}/health/ready > /dev/null 2>&1; do sleep 5; done"
pass "Keycloak restarted successfully"

TOKEN=$(kc_token 2>/dev/null || echo "")
REALM_AFTER=$(kc_api "/${KC_REALM}" "${TOKEN}" 2>/dev/null | grep -o '"realm":"[^"]*"' | head -1 || echo "")
if [ -n "${REALM_AFTER}" ]; then
  pass "Realm '${KC_REALM}' persisted after Keycloak restart (external DB working)"
else
  fail "Realm '${KC_REALM}' lost after restart — data not persisted to external DB"
fi

header "Phase 6: OIDC Discovery"
DISC=$(curl -sf --max-time 5 "${KC_URL}/realms/${KC_REALM}/.well-known/openid-configuration" 2>/dev/null \
  | grep -o '"issuer":"[^"]*"' | head -1 || echo "")
if [ -n "${DISC}" ]; then
  pass "OIDC discovery document available: ${DISC}"
else
  fail "OIDC discovery document not available"
fi

header "Phase 7: Network Segmentation"
# Verify db-net is marked as internal (DB not directly internet-accessible)
DB_NET=$(docker network inspect it-stack-keycloak-db-net 2>/dev/null \
  | grep -o '"Internal": [a-z]*' | head -1 || echo "")
if echo "${DB_NET}" | grep -q "true"; then
  pass "DB network is internal (not internet-routable)"
else
  warn "DB network internal flag: '${DB_NET}'"
fi

header "Phase 8: Cleanup"
TOKEN=$(kc_token 2>/dev/null || echo "")
if [ -n "${TOKEN}" ]; then
  DEL_CODE=$(curl -so /dev/null -w "%{http_code}" --max-time 10 -X DELETE \
    -H "Authorization: Bearer ${TOKEN}" \
    "${KC_URL}/admin/realms/${KC_REALM}" 2>/dev/null || echo "000")
  if [ "${DEL_CODE}" = "204" ]; then
    pass "Test realm deleted (HTTP 204)"
  else
    warn "Realm deletion returned HTTP ${DEL_CODE}"
  fi
fi
docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
pass "Stack stopped and volumes removed"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}Lab ${LAB_ID} Results${NC}"
echo -e "  ${GREEN}Passed:${NC} ${PASS}"
echo -e "  ${RED}Failed:${NC} ${FAIL}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [ "${FAIL}" -gt 0 ]; then
  echo -e "${RED}FAIL${NC} — ${FAIL} test(s) failed"; exit 1
fi
echo -e "${GREEN}PASS${NC} — All ${PASS} tests passed"