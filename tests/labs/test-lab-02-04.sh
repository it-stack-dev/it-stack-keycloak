#!/usr/bin/env bash
# test-lab-02-04.sh — Keycloak Lab 04: Full OIDC/SAML SSO Hub
# Tests: realm config, OIDC client flows, SAML metadata, ROPC grant,
#        refresh tokens, JWT decode, token introspection, MailHog email
set -euo pipefail

PASS=0; FAIL=0
KC_PASS="${KC_PASS:-Lab04Password!}"
KC_URL="http://localhost:8080"
REALM="it-stack"

pass()  { ((++PASS)); echo "  [PASS] $1"; }
fail()  { ((++FAIL)); echo "  [FAIL] $1"; }
warn()  { echo "  [WARN] $1"; }
header(){ echo; echo "=== $1 ==="; }

kc_token() {
  curl -sf -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli&grant_type=password&username=admin&password=${KC_PASS}" \
    | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
}

header "1. Keycloak Health"
if curl -sf "$KC_URL/health/ready" | grep -q '"status":"UP"'; then
  pass "Keycloak /health/ready UP"
else
  fail "Keycloak not ready"; exit 1
fi

header "2. Admin Authentication"
TOKEN=$(kc_token)
[[ -n "$TOKEN" ]] && pass "Admin token from master realm" || { fail "Admin auth failed"; exit 1; }

header "3. Realm Creation + Config"
curl -sf -X POST "$KC_URL/admin/realms" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"realm\":\"$REALM\",\"enabled\":true,\"displayName\":\"IT-Stack\",
       \"bruteForceProtected\":true,\"ssoSessionMaxLifespan\":86400}" \
  -o /dev/null && pass "Realm '$REALM' created" || warn "Realm may exist"

TOKEN=$(kc_token)
REALM_INFO=$(curl -sf "$KC_URL/admin/realms/$REALM" -H "Authorization: Bearer $TOKEN")
echo "$REALM_INFO" | grep -q '"enabled":true' && pass "Realm is enabled" || fail "Realm not enabled"
echo "$REALM_INFO" | grep -q '"bruteForceProtected":true' && pass "Brute force protection enabled" || fail "Brute force not enabled"

header "4. OIDC Client (confidential + service account + ROPC)"
TOKEN=$(kc_token)
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$KC_URL/admin/realms/$REALM/clients" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"clientId\":\"oidc-client\",\"secret\":\"$KC_PASS\",\"publicClient\":false,
       \"serviceAccountsEnabled\":true,\"directAccessGrantsEnabled\":true,
       \"redirectUris\":[\"http://localhost:9000/*\"],\"enabled\":true}")
[[ "$STATUS" =~ ^(201|409)$ ]] && pass "OIDC client 'oidc-client' ready (HTTP $STATUS)" || fail "OIDC client failed (HTTP $STATUS)"

header "5. SAML Client Registration"
TOKEN=$(kc_token)
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$KC_URL/admin/realms/$REALM/clients" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"clientId\":\"saml-client\",\"protocol\":\"saml\",
       \"redirectUris\":[\"http://localhost:9001/*\"],\"enabled\":true}")
[[ "$STATUS" =~ ^(201|409)$ ]] && pass "SAML client 'saml-client' ready (HTTP $STATUS)" || fail "SAML client failed (HTTP $STATUS)"

header "6. Test User Creation"
TOKEN=$(kc_token)
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$KC_URL/admin/realms/$REALM/users" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"username\":\"labuser\",\"enabled\":true,\"email\":\"labuser@lab.local\",
       \"emailVerified\":true,\"firstName\":\"Lab\",\"lastName\":\"User\",
       \"credentials\":[{\"type\":\"password\",\"value\":\"$KC_PASS\",\"temporary\":false}]}")
[[ "$STATUS" =~ ^(201|409)$ ]] && pass "User 'labuser' ready (HTTP $STATUS)" || fail "User creation failed (HTTP $STATUS)"

header "7. Client Credentials Grant (OAuth2 M2M)"
SA_TOKEN=$(curl -sf -X POST "$KC_URL/realms/$REALM/protocol/openid-connect/token" \
  -d "client_id=oidc-client&client_secret=${KC_PASS}&grant_type=client_credentials" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
[[ -n "$SA_TOKEN" ]] && pass "Client credentials grant: access token obtained" || fail "Client credentials grant failed"

header "8. JWT Structure + Claims"
IFS='.' read -ra P <<< "$SA_TOKEN"
[[ "${#P[@]}" -eq 3 ]] && pass "JWT has 3 parts (header.payload.sig)" || fail "Invalid JWT structure"
if [[ "${#P[@]}" -eq 3 ]]; then
  PAD=$(( 4 - ${#P[1]} % 4 )); [[ "$PAD" -lt 4 ]] && P[1]+=$(printf '%0.s=' $(seq 1 $PAD))
  PAYLOAD=$(echo "${P[1]}" | base64 -d 2>/dev/null || true)
  for claim in iss exp iat; do
    echo "$PAYLOAD" | grep -q "\"$claim\"" && pass "JWT claim '$claim' present" || fail "JWT missing '$claim'"
  done
fi

header "9. Resource Owner Password Credentials (user login)"
ROPC=$(curl -sf -X POST "$KC_URL/realms/$REALM/protocol/openid-connect/token" \
  -d "client_id=oidc-client&client_secret=${KC_PASS}&grant_type=password&username=labuser&password=${KC_PASS}" \
  2>/dev/null || echo "{}")
echo "$ROPC" | grep -q '"access_token"' && pass "ROPC grant: user token obtained" || fail "ROPC grant failed"
REFRESH=$(echo "$ROPC" | grep -o '"refresh_token":"[^"]*"' | cut -d'"' -f4 || true)

header "10. Token Refresh"
if [[ -n "$REFRESH" ]]; then
  REFRESHED=$(curl -sf -X POST "$KC_URL/realms/$REALM/protocol/openid-connect/token" \
    -d "client_id=oidc-client&client_secret=${KC_PASS}&grant_type=refresh_token&refresh_token=${REFRESH}" \
    | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4 || true)
  [[ -n "$REFRESHED" ]] && pass "Token refresh succeeded" || fail "Token refresh failed"
else
  fail "No refresh token to test"
fi

header "11. Token Introspection"
TOKEN=$(kc_token)
INTRO=$(curl -sf -X POST "$KC_URL/realms/$REALM/protocol/openid-connect/token/introspect" \
  -u "oidc-client:${KC_PASS}" -d "token=${SA_TOKEN}" | grep -o '"active":[a-z]*')
echo "$INTRO" | grep -q '"active":true' && pass "Token introspection: active=true" || fail "Token not active"

header "12. OIDC Discovery"
DISC=$(curl -sf "$KC_URL/realms/$REALM/.well-known/openid-configuration")
for f in token_endpoint authorization_endpoint jwks_uri userinfo_endpoint introspection_endpoint; do
  echo "$DISC" | grep -q "\"$f\"" && pass "Discovery: $f present" || fail "Discovery missing $f"
done

header "13. SAML Metadata Endpoint"
SAML_META=$(curl -sf "$KC_URL/realms/$REALM/protocol/saml/descriptor")
echo "$SAML_META" | grep -q "EntityDescriptor\|IDPSSODescriptor" \
  && pass "SAML metadata XML returned" || fail "SAML metadata not available"

header "14. Client List (verify both OIDC + SAML present)"
TOKEN=$(kc_token)
CLIENTS=$(curl -sf "$KC_URL/admin/realms/$REALM/clients" -H "Authorization: Bearer $TOKEN")
echo "$CLIENTS" | grep -q '"oidc-client"' && pass "OIDC client visible in realm" || fail "OIDC client not found"
echo "$CLIENTS" | grep -q '"saml-client"' && pass "SAML client visible in realm" || fail "SAML client not found"

header "15. MailHog Email Sink"
if curl -sf http://localhost:8025/ -o /dev/null; then
  pass "MailHog UI accessible (:8025)"
  curl -sf http://localhost:8025/api/v2/messages | grep -q '"total"' \
    && pass "MailHog API v2 messages endpoint works" || fail "MailHog API failed"
else
  fail "MailHog not accessible"
fi

echo
echo "═══════════════════════════════════════"
echo " Lab 02-04 Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]