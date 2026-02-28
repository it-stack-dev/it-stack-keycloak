#!/usr/bin/env bash
# test-lab-02-05.sh -- Keycloak Lab 05: Advanced Integration
# Tests: Keycloak + OpenLDAP federation + phpLDAPadmin + MailHog + multi OIDC clients
# Usage: KC_PASS=Lab05Password! bash test-lab-02-05.sh
set -euo pipefail

KC_PASS="${KC_PASS:-Lab05Password!}"
LDAP_ADMIN_PASS="${LDAP_ADMIN_PASS:-admin}"
PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; ((PASS++)); }
fail(){ echo "[FAIL] $1"; ((FAIL++)); }
info(){ echo "[INFO] $1"; }

# -- Section 1: Keycloak health -----------------------------------------------
info "Section 1: Keycloak health"
resp=$(curl -sf http://localhost:8080/health/ready 2>/dev/null || true)
if echo "$resp" | grep -qi '"status".*"UP"\|status.*up'; then ok "Keycloak /health/ready"; else fail "Keycloak /health/ready"; fi

# -- Section 2: Admin token ---------------------------------------------------
info "Section 2: Keycloak admin token"
token=$(curl -sf -X POST http://localhost:8080/realms/master/protocol/openid-connect/token \
  -d "client_id=admin-cli&grant_type=password&username=admin&password=${KC_PASS}" \
  2>/dev/null | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4 || true)
if [[ -n "$token" ]]; then ok "Admin token obtained"; else fail "Admin token obtained"; fi

# -- Section 3: OpenLDAP port check -------------------------------------------
info "Section 3: OpenLDAP :389 availability"
if command -v ldapsearch >/dev/null 2>&1; then
  ldap_result=$(ldapsearch -x -H ldap://localhost:389 \
    -D "cn=admin,dc=lab,dc=local" -w "${LDAP_ADMIN_PASS}" \
    -b "dc=lab,dc=local" "(objectClass=domain)" dn 2>/dev/null || true)
  if echo "$ldap_result" | grep -q "dc=lab"; then
    ok "OpenLDAP admin bind and base DN found"
  else
    fail "OpenLDAP admin bind"
  fi
else
  ldap_open=$(nc -z localhost 389 2>/dev/null && echo "open" || echo "closed")
  if [[ "$ldap_open" == "open" ]]; then ok "OpenLDAP :389 port open"; else fail "OpenLDAP :389 port open"; fi
fi

# -- Section 4: phpLDAPadmin --------------------------------------------------
info "Section 4: phpLDAPadmin :6443 accessible"
pla_status=$(curl -so /dev/null -w "%{http_code}" http://localhost:6443 2>/dev/null || echo "000")
info "phpLDAPadmin -> $pla_status"
if [[ "$pla_status" == "200" || "$pla_status" == "301" || "$pla_status" == "302" ]]; then
  ok "phpLDAPadmin :6443 accessible ($pla_status)"
else
  fail "phpLDAPadmin :6443 accessible (got $pla_status)"
fi

# -- Section 5: Create realm and LDAP federation ------------------------------
info "Section 5: Create realm it-stack and LDAP federation component"
if [[ -n "$token" ]]; then
  curl -sf -X POST http://localhost:8080/admin/realms \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -d '{"realm":"it-stack","enabled":true,"displayName":"IT-Stack Lab 05"}' 2>/dev/null || true

  curl -sf -X POST "http://localhost:8080/admin/realms/it-stack/components" \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -d '{
      "name":"openldap-federation",
      "providerId":"ldap",
      "providerType":"org.keycloak.storage.UserStorageProvider",
      "config":{
        "vendor":["other"],
        "connectionUrl":["ldap://openldap:389"],
        "bindDn":["cn=admin,dc=lab,dc=local"],
        "bindCredential":["admin"],
        "usersDn":["ou=people,dc=lab,dc=local"],
        "usernameLDAPAttribute":["uid"],
        "rdnLDAPAttribute":["uid"],
        "uuidLDAPAttribute":["entryUUID"],
        "userObjectClasses":["inetOrgPerson"],
        "importEnabled":["true"],
        "syncRegistrations":["false"],
        "enabled":["true"]
      }
    }' 2>/dev/null || true

  comp_count=$(curl -sf \
    "http://localhost:8080/admin/realms/it-stack/components?type=org.keycloak.storage.UserStorageProvider" \
    -H "Authorization: Bearer $token" 2>/dev/null | grep -c '"providerId"' || true)
  [[ "$comp_count" -ge 1 ]] && ok "LDAP federation component created" || fail "LDAP federation component created"
fi

# -- Section 6: OIDC clients app-a and app-b ----------------------------------
info "Section 6: Create OIDC clients app-a and app-b"
if [[ -n "$token" ]]; then
  for client in "app-a" "app-b"; do
    curl -sf -X POST "http://localhost:8080/admin/realms/it-stack/clients" \
      -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
      -d "{\"clientId\":\"${client}\",\"publicClient\":false,\"protocol\":\"openid-connect\",\"enabled\":true,\"serviceAccountsEnabled\":true}" \
      2>/dev/null || true
  done
  client_count=$(curl -sf "http://localhost:8080/admin/realms/it-stack/clients" \
    -H "Authorization: Bearer $token" 2>/dev/null | grep -o '"clientId"' | wc -l | tr -d ' ' || echo 0)
  info "Clients in realm it-stack: $client_count"
  if [[ "$client_count" -ge 2 ]]; then ok "OIDC clients app-a and app-b created"; else fail "OIDC clients app-a and app-b (found $client_count)"; fi
fi

# -- Section 7: Client credentials flow for app-a -----------------------------
info "Section 7: Client credentials flow -- app-a"
if [[ -n "$token" ]]; then
  client_uuid=$(curl -sf "http://localhost:8080/admin/realms/it-stack/clients?clientId=app-a" \
    -H "Authorization: Bearer $token" 2>/dev/null | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
  info "app-a UUID: $client_uuid"
  if [[ -n "$client_uuid" ]]; then
    secret=$(curl -sf -X POST \
      "http://localhost:8080/admin/realms/it-stack/clients/${client_uuid}/client-secret" \
      -H "Authorization: Bearer $token" 2>/dev/null | grep -o '"value":"[^"]*"' | cut -d'"' -f4 || true)
    if [[ -n "$secret" ]]; then
      app_token=$(curl -sf -X POST \
        "http://localhost:8080/realms/it-stack/protocol/openid-connect/token" \
        -d "grant_type=client_credentials&client_id=app-a&client_secret=${secret}" \
        2>/dev/null | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4 || true)
      [[ -n "$app_token" ]] && ok "app-a client credentials token issued" || fail "app-a client credentials token issued"
    else
      fail "app-a client secret returned"
    fi
  else
    fail "app-a client UUID lookup"
  fi
fi

# -- Section 8: OIDC discovery ------------------------------------------------
info "Section 8: OIDC discovery for realm it-stack"
discovery=$(curl -sf "http://localhost:8080/realms/it-stack/.well-known/openid-configuration" 2>/dev/null || true)
required=("issuer" "authorization_endpoint" "token_endpoint" "jwks_uri" "userinfo_endpoint")
disc_pass=0
for field in "${required[@]}"; do
  echo "$discovery" | grep -q "\"${field}\"" && ((disc_pass++)) || true
done
info "OIDC discovery fields present: $disc_pass/5"
if [[ "$disc_pass" -ge 5 ]]; then ok "OIDC discovery has all 5 required fields"; else fail "OIDC discovery fields (got $disc_pass/5)"; fi

# -- Section 9: SAML descriptor -----------------------------------------------
info "Section 9: SAML 2.0 descriptor endpoint"
saml_status=$(curl -so /dev/null -w "%{http_code}" \
  "http://localhost:8080/realms/it-stack/protocol/saml/descriptor" 2>/dev/null || echo "000")
if [[ "$saml_status" == "200" ]]; then ok "SAML 2.0 descriptor available"; else fail "SAML 2.0 descriptor (got $saml_status)"; fi

# -- Section 10: MailHog ------------------------------------------------------
info "Section 10: MailHog :8025"
mh_status=$(curl -so /dev/null -w "%{http_code}" http://localhost:8025 2>/dev/null || echo "000")
info "MailHog -> $mh_status"
if [[ "$mh_status" == "200" ]]; then ok "MailHog :8025 accessible"; else fail "MailHog :8025 accessible (got $mh_status)"; fi
mh_api=$(curl -sf "http://localhost:8025/api/v2/messages" 2>/dev/null | grep -c '"items"' || echo 0)
if [[ "$mh_api" -ge 1 ]]; then ok "MailHog API /api/v2/messages responds"; else fail "MailHog API /api/v2/messages"; fi

# -- Section 11: App service ports --------------------------------------------
info "Section 11: App services :9001 and :9002"
for port in 9001 9002; do
  st=$(curl -so /dev/null -w "%{http_code}" "http://localhost:${port}" 2>/dev/null || echo "000")
  if [[ "$st" == "200" ]]; then ok "App :${port} -> 200"; else fail "App :${port} -> 200 (got $st)"; fi
done

# -- Section 12: Realm count --------------------------------------------------
info "Section 12: Realm list"
if [[ -n "$token" ]]; then
  realm_count=$(curl -sf http://localhost:8080/admin/realms \
    -H "Authorization: Bearer $token" 2>/dev/null | grep -o '"realm"' | wc -l | tr -d ' ' || echo 0)
  info "Realms found: $realm_count"
  if [[ "$realm_count" -ge 2 ]]; then ok "At least 2 realms (master + it-stack)"; else fail "At least 2 realms (found $realm_count)"; fi
fi

# -- Section 13: Integration score --------------------------------------------
info "Section 13: Integration score"
TOTAL=$((PASS + FAIL))
echo "Results: $PASS/$TOTAL passed"
if [[ $FAIL -eq 0 ]]; then
  echo "[SCORE] 5/5 -- All integration checks passed"
  exit 0
else
  echo "[SCORE] FAIL ($FAIL failures)"
  exit 1
fi
