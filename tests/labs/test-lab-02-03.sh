#!/usr/bin/env bash
# test-lab-02-03.sh — Keycloak Lab 03: Advanced Features
# Tests: 2-node cluster, SMTP/email flow via MailHog, brute force, token policies
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
pass() { echo -e "${GREEN}  PASS${NC} $1"; ((++PASS)); }
fail() { echo -e "${RED}  FAIL${NC} $1"; ((++FAIL)); }
warn() { echo -e "${YELLOW}  WARN${NC} $1"; }
header() { echo -e "\n${BLUE}══ $1 ══${NC}"; }

PASS=0; FAIL=0
KC_PASS="${KC_PASS:-Lab03Password!}"
KC1="http://localhost:8080"
KC2="http://localhost:8081"

kc_token() {
  local url=$1
  curl -sf "${url}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" -d "grant_type=password" \
    -d "username=admin" -d "password=${KC_PASS}" 2>/dev/null \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
}
kc_api() { local url=$1; local token=$2; shift 2; curl -sf -H "Authorization: Bearer $token" "$@" "${url}"; }

# ── 1. Node 1 health ─────────────────────────────────────────────────────────
header "1. Node Health"
code1=$(curl -so /dev/null -w "%{http_code}" "${KC1}/health/ready" 2>/dev/null || echo "000")
if [[ "$code1" == "200" ]]; then pass "Node 1 /health/ready → 200"
else fail "Node 1 /health/ready → $code1"; fi

code2=$(curl -so /dev/null -w "%{http_code}" "${KC2}/health/ready" 2>/dev/null || echo "000")
if [[ "$code2" == "200" ]]; then pass "Node 2 /health/ready → 200"
else fail "Node 2 /health/ready → $code2"; fi

# ── 2. Admin tokens from both nodes ──────────────────────────────────────────
header "2. Admin Authentication (both nodes)"
TOKEN1=$(kc_token "$KC1")
if [[ -n "$TOKEN1" ]]; then pass "Node 1: admin token obtained"
else fail "Node 1: admin token failed"; fi

TOKEN2=$(kc_token "$KC2")
if [[ -n "$TOKEN2" ]]; then pass "Node 2: admin token obtained"
else fail "Node 2: admin token failed"; fi

# ── 3. Shared database — realm visible on both nodes ────────────────────────
header "3. Shared Database (session replication)"
REALM_NAME="lab03-cluster-test"
# Create realm on node 1
create_code=$(curl -so /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN1" \
  -H "Content-Type: application/json" \
  -X POST "${KC1}/admin/realms" \
  -d "{\"realm\":\"${REALM_NAME}\",\"enabled\":true}" 2>/dev/null || echo "000")
if [[ "$create_code" =~ ^(201|409)$ ]]; then pass "Realm created on node 1 ($create_code)"
else fail "Realm create on node 1: $create_code"; fi

sleep 2  # allow DB replication propagation
TOKEN2=$(kc_token "$KC2")  # refresh
realm_check=$(curl -so /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN2" \
  "${KC2}/admin/realms/${REALM_NAME}" 2>/dev/null || echo "000")
if [[ "$realm_check" == "200" ]]; then pass "Realm visible on node 2 (shared DB confirmed)"
else fail "Realm not visible on node 2 ($realm_check)"; fi

# ── 4. MailHog SMTP endpoint ─────────────────────────────────────────────────
header "4. MailHog SMTP Gateway"
mailhog_code=$(curl -so /dev/null -w "%{http_code}" http://localhost:8025 2>/dev/null || echo "000")
if [[ "$mailhog_code" =~ ^2[0-9]{2}$ ]]; then pass "MailHog web UI accessible (:8025 → $mailhog_code)"
else fail "MailHog web UI not accessible (:8025 → $mailhog_code)"; fi

# ── 5. Configure realm SMTP settings ─────────────────────────────────────────
header "5. SMTP Configuration"
TOKEN1=$(kc_token "$KC1")
smtp_payload='{
  "smtpServer": {
    "host": "mailhog",
    "port": "1025",
    "from": "noreply@lab.localhost",
    "fromDisplayName": "IT-Stack Lab",
    "auth": "false",
    "ssl": "false",
    "starttls": "false"
  }
}'
smtp_code=$(curl -so /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN1" \
  -H "Content-Type: application/json" \
  -X PUT "${KC1}/admin/realms/${REALM_NAME}" \
  -d "$smtp_payload" 2>/dev/null || echo "000")
if [[ "$smtp_code" =~ ^(200|204)$ ]]; then pass "Realm SMTP configured (mailhog host)"
else fail "Realm SMTP config failed ($smtp_code)"; fi

# ── 6. Brute force protection ─────────────────────────────────────────────────
header "6. Brute Force Protection"
bf_payload='{"enabled":true,"maxLoginFailures":5,"waitIncrementSeconds":10,"minimumQuickLoginWaitSeconds":10,"maxWait":900}'
bf_code=$(curl -so /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN1" \
  -H "Content-Type: application/json" \
  -X PUT "${KC1}/admin/realms/${REALM_NAME}" \
  -d '{"bruteForceProtected":true,"failureFactor":5,"maxDeltaTimeSeconds":43200}' 2>/dev/null || echo "000")
if [[ "$bf_code" =~ ^(200|204)$ ]]; then pass "Brute force protection enabled on realm"
else fail "Brute force config failed ($bf_code)"; fi

realm_config=$(curl -sf \
  -H "Authorization: Bearer $TOKEN1" \
  "${KC1}/admin/realms/${REALM_NAME}" 2>/dev/null || echo "{}")
if echo "$realm_config" | grep -q '"bruteForceProtected":true'; then
  pass "Realm config confirms bruteForceProtected: true"
else fail "bruteForceProtected not set in realm config"; fi

# ── 7. Token lifetime configuration ──────────────────────────────────────────
header "7. Token Lifetime Policy"
tl_code=$(curl -so /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN1" \
  -H "Content-Type: application/json" \
  -X PUT "${KC1}/admin/realms/${REALM_NAME}" \
  -d '{"accessTokenLifespan":300,"ssoSessionMaxLifespan":36000}' 2>/dev/null || echo "000")
if [[ "$tl_code" =~ ^(200|204)$ ]]; then pass "Token lifetime: access=5m, SSO=10h"
else fail "Token lifetime config failed ($tl_code)"; fi

realm_tl=$(curl -sf -H "Authorization: Bearer $TOKEN1" "${KC1}/admin/realms/${REALM_NAME}" 2>/dev/null || echo "{}")
tl_val=$(echo "$realm_tl" | grep -o '"accessTokenLifespan":[0-9]*' | cut -d: -f2)
if [[ "$tl_val" == "300" ]]; then pass "accessTokenLifespan = 300 (5 minutes)"
else fail "accessTokenLifespan = '$tl_val' (expected 300)"; fi

# ── 8. Custom client scope ────────────────────────────────────────────────────
header "8. Custom Client Scope"
scope_payload='{"name":"it-stack:read","description":"Read access to IT-Stack resources","protocol":"openid-connect","attributes":{"include.in.token.scope":"true"}}'
scope_code=$(curl -so /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN1" \
  -H "Content-Type: application/json" \
  -X POST "${KC1}/admin/realms/${REALM_NAME}/client-scopes" \
  -d "$scope_payload" 2>/dev/null || echo "000")
if [[ "$scope_code" =~ ^(201|409)$ ]]; then pass "Custom scope 'it-stack:read' created ($scope_code)"
else fail "Custom scope creation failed ($scope_code)"; fi

scopes=$(curl -sf -H "Authorization: Bearer $TOKEN1" "${KC1}/admin/realms/${REALM_NAME}/client-scopes" 2>/dev/null || echo "[]")
if echo "$scopes" | grep -q "it-stack:read"; then pass "Custom scope 'it-stack:read' visible in API"
else fail "Custom scope not found in API response"; fi

# ── 9. OIDC discovery on both nodes ──────────────────────────────────────────
header "9. OIDC Discovery"
TOKEN1=$(kc_token "$KC1"); TOKEN2=$(kc_token "$KC2")
for url in "$KC1" "$KC2"; do
  oidc=$(curl -sf "${url}/realms/${REALM_NAME}/.well-known/openid-configuration" 2>/dev/null || echo "{}")
  if echo "$oidc" | grep -q "authorization_endpoint"; then pass "OIDC discovery: $url"
  else fail "OIDC discovery failed: $url"; fi
done

# ── Cleanup ───────────────────────────────────────────────────────────────────
TOKEN1=$(kc_token "$KC1")
curl -s -X DELETE -H "Authorization: Bearer $TOKEN1" "${KC1}/admin/realms/${REALM_NAME}" >/dev/null 2>&1 || true

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════"
echo -e "  Tests passed: ${GREEN}${PASS}${NC}"
echo -e "  Tests failed: ${RED}${FAIL}${NC}"
echo "══════════════════════════════════════════"
[[ $FAIL -eq 0 ]] && echo -e "${GREEN}Lab 02-03 PASSED${NC}" || { echo -e "${RED}Lab 02-03 FAILED${NC}"; exit 1; }
