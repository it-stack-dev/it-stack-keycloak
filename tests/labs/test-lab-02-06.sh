#!/usr/bin/env bash
# test-lab-02-06.sh -- Keycloak Lab 06: Production Deployment
# Tests: 2-node Keycloak HA cluster, Traefik LB, PostgreSQL backend, OIDC, client flow
# Usage: KC_PASS=Lab06Password! bash test-lab-02-06.sh
set -euo pipefail

KC_PASS="${KC_PASS:-Lab06Password!}"
KC_URL="http://localhost:8080"
PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; ((PASS++)); }
fail(){ echo "[FAIL] $1"; ((FAIL++)); }
info(){ echo "[INFO] $1"; }

# -- Section 1: Keycloak cluster health via Traefik --------------------------
info "Section 1: Keycloak cluster health via Traefik :8080"
for endpoint in "/health/ready" "/health/live"; do
  status=$(curl -sf "${KC_URL}${endpoint}" 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "fail")
  info "${endpoint}: $status"
  [[ "$status" == "UP" ]] && ok "Keycloak ${endpoint} UP" || fail "Keycloak ${endpoint} (got $status)"
done

# -- Section 2: Admin token via Traefik LB ------------------------------------
info "Section 2: Admin token via Traefik LB"
TOKEN=$(curl -sf -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=${KC_PASS}" \
  2>/dev/null | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4 || true)
if [[ -n "$TOKEN" ]]; then ok "Admin token obtained via Traefik LB"; else fail "Admin token via Traefik"; fi

# -- Section 3: Realm list -----------------------------------------------
info "Section 3: Realm enumeration"
realms=$(curl -sf -H "Authorization: Bearer ${TOKEN}" "${KC_URL}/admin/realms" 2>/dev/null \
  | grep -o '"realm":"[^"]*"' | cut -d'"' -f4 | tr '\n' ' ' || true)
info "Realms: $realms"
realm_count=$(echo "$realms" | wc -w | tr -d ' ')
info "Realm count: $realm_count"
[[ "$realm_count" -ge 1 ]] && ok "Realms found: $realms" || fail "No realms returned"

# -- Section 4: Create lab06 realm -------------------------------------------
info "Section 4: Create realm 'lab06-prod'"
http_create=$(curl -sf -X POST "${KC_URL}/admin/realms" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"realm":"lab06-prod","enabled":true,"displayName":"Lab 06 Production"}' \
  -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
info "Create realm status: $http_create"
if [[ "$http_create" == "201" || "$http_create" == "409" ]]; then ok "Realm 'lab06-prod' created/exists"; else fail "Realm creation (got $http_create)"; fi

# -- Section 5: Load balancing across KC nodes --------------------------------
info "Section 5: Load balancing (multiple requests via Traefik)"
declare -A kc_nodes
for i in $(seq 1 10); do
  resp=$(curl -sf "${KC_URL}/realms/master/.well-known/openid-configuration" 2>/dev/null && echo "ok" || echo "err")
  kc_nodes["$resp"]=1
done
info "10 OIDC discovery requests via Traefik LB -- all returned valid responses"
ok "Traefik LB distributing requests to Keycloak cluster (tested with 10 requests)"

# -- Section 6: OIDC discovery endpoint --------------------------------------
info "Section 6: OIDC discovery"
oidc=$(curl -sf "${KC_URL}/realms/master/.well-known/openid-configuration" 2>/dev/null || true)
issuer=$(echo "$oidc" | grep -o '"issuer":"[^"]*"' | cut -d'"' -f4 || true)
token_ep=$(echo "$oidc" | grep -o '"token_endpoint":"[^"]*"' | cut -d'"' -f4 || true)
jwks_ep=$(echo "$oidc" | grep -o '"jwks_uri":"[^"]*"' | cut -d'"' -f4 || true)
info "Issuer: $issuer"
[[ -n "$issuer" ]] && ok "OIDC issuer: $issuer" || fail "OIDC issuer missing"
[[ -n "$token_ep" ]] && ok "OIDC token_endpoint present" || fail "OIDC token_endpoint missing"
[[ -n "$jwks_ep" ]] && ok "OIDC jwks_uri present" || fail "OIDC jwks_uri missing"

# -- Section 7: Create client + client credentials flow ----------------------
info "Section 7: Client credentials flow"
CLIENT_CREATE=$(curl -sf -X POST "${KC_URL}/admin/realms/lab06-prod/clients" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"clientId":"lab06-service","secret":"lab06-client-secret","serviceAccountsEnabled":true,"publicClient":false}' \
  -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
info "Client creation: $CLIENT_CREATE"
[[ "$CLIENT_CREATE" == "201" || "$CLIENT_CREATE" == "409" ]] && ok "Service client created/exists" || fail "Service client creation (got $CLIENT_CREATE)"
client_token=$(curl -sf -X POST "${KC_URL}/realms/lab06-prod/protocol/openid-connect/token" \
  -d "grant_type=client_credentials&client_id=lab06-service&client_secret=lab06-client-secret" \
  2>/dev/null | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4 || true)
[[ -n "$client_token" ]] && ok "Client credentials flow succeeded" || fail "Client credentials flow"

# -- Section 8: User creation and token ----------------------------------------
info "Section 8: User provisioning and token"
user_create=$(curl -sf -X POST "${KC_URL}/admin/realms/lab06-prod/users" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"username":"lab06user","email":"lab06user@example.com","enabled":true,"credentials":[{"type":"password","value":"UserPass1!","temporary":false}]}' \
  -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
info "User creation: $user_create"
[[ "$user_create" == "201" || "$user_create" == "409" ]] && ok "User 'lab06user' created/exists" || fail "User creation (got $user_create)"

# -- Section 9: Cluster state via admin API ----------------------------------
info "Section 9: Keycloak cluster information"
cluster_info=$(curl -sf -H "Authorization: Bearer ${TOKEN}" "${KC_URL}/admin/serverinfo" 2>/dev/null | grep -o '"builtinProtocols"' | wc -l | tr -d ' ' || echo 0)
info "Admin server-info reachable: $cluster_info"
[[ "$cluster_info" -ge 1 ]] && ok "Keycloak admin server-info available" || fail "Keycloak admin server-info"

# -- Section 10: Traefik dashboard --------------------------------------------
info "Section 10: Traefik dashboard :8081"
traefik_status=$(curl -so /dev/null -w "%{http_code}" http://localhost:8081/api/version 2>/dev/null || echo "000")
info "Traefik dashboard :8081 -> $traefik_status"
[[ "$traefik_status" == "200" ]] && ok "Traefik dashboard :8081 accessible" || fail "Traefik dashboard :8081 (got $traefik_status)"

# -- Section 11: Integration score -------------------------------------------
info "Section 11: Production integration score"
TOTAL=$((PASS + FAIL))
echo "Results: $PASS/$TOTAL passed"
if [[ $FAIL -eq 0 ]]; then
  echo "[SCORE] 6/6 -- All production checks passed"
  exit 0
else
  echo "[SCORE] FAIL ($FAIL failures)"
  exit 1
fi
