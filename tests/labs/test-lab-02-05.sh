#!/usr/bin/env bash
# test-lab-02-05.sh -- Keycloak Lab 05: Advanced Integration (FreeIPA Federation)
# Tests:
#   - Keycloak health + admin API
#   - OpenLDAP seeded with FreeIPA-compatible structure (users, groups)
#   - Keycloak LDAP federation using FreeIPA-like DN paths
#   - Group mapper: cn=admins → Keycloak admins group
#   - Full LDAP sync: assert users have federationLink
#   - OIDC multi-client, client credentials, discovery, SAML, MailHog, whoami apps
#
# Usage:
#   KC_PASS=Lab05Password! bash test-lab-02-05.sh
#
# Requirements: curl, ldapsearch (ldap-utils), nc or /dev/tcp
# Seeded LDAP users and groups: see docker/openldap-seed.ldif
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
KC_PASS="${KC_PASS:-Lab05Password!}"
KC_BASE="http://localhost:8080"
LDAP_ADMIN_PASS="${LDAP_ADMIN_PASS:-Lab05Password!}"
LDAP_BASE="dc=lab,dc=local"
LDAP_BIND_DN="cn=admin,${LDAP_BASE}"
LDAP_READONLY_DN="cn=readonly,${LDAP_BASE}"
LDAP_USERS_DN="cn=users,cn=accounts,${LDAP_BASE}"
LDAP_GROUPS_DN="cn=groups,cn=accounts,${LDAP_BASE}"
REALM="it-stack"
SYNC_WAIT=15   # seconds to wait for LDAP sync to complete

# ─── Helpers ─────────────────────────────────────────────────────────────────
PASS=0; FAIL=0
ok()    { echo "[PASS] $1"; ((PASS++)); }
fail()  { echo "[FAIL] $1"; ((FAIL++)); }
info()  { echo "[INFO] $1"; }
section(){ echo ""; echo "══════════════════════════════════════════════"; echo "  Section $1: $2"; echo "══════════════════════════════════════════════"; }

# ─── Section 1: Keycloak health ────────────────────────────────────────────────
section 1 "Keycloak health"
resp=$(curl -sf "${KC_BASE}/health/ready" 2>/dev/null || true)
if echo "$resp" | grep -qi '"status".*"UP"\|status.*up'; then
  ok "Keycloak /health/ready → UP"
else
  fail "Keycloak /health/ready → UP  (got: ${resp:0:120})"
fi

# ─── Section 2: Admin API token ────────────────────────────────────────────────
section 2 "Admin API token"
token=$(curl -sf -X POST "${KC_BASE}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli&grant_type=password&username=admin&password=${KC_PASS}" \
  2>/dev/null | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4 || true)
if [[ -n "$token" ]]; then
  ok "Admin token obtained (${#token} chars)"
else
  fail "Admin token obtained"
fi

# ─── Section 3: OpenLDAP availability + seeded structure ───────────────────────
section 3 "OpenLDAP: availability and FreeIPA-like seed structure"
if command -v ldapsearch >/dev/null 2>&1; then
  # Base bind
  base_result=$(ldapsearch -x -H ldap://localhost:389 \
    -D "${LDAP_BIND_DN}" -w "${LDAP_ADMIN_PASS}" \
    -b "${LDAP_BASE}" -s base dn 2>/dev/null || true)
  if echo "$base_result" | grep -q "${LDAP_BASE}"; then
    ok "OpenLDAP admin bind + base DN"
  else
    fail "OpenLDAP admin bind + base DN"
  fi

  # cn=accounts container
  acct_result=$(ldapsearch -x -H ldap://localhost:389 \
    -D "${LDAP_BIND_DN}" -w "${LDAP_ADMIN_PASS}" \
    -b "cn=accounts,${LDAP_BASE}" -s base dn 2>/dev/null || true)
  if echo "$acct_result" | grep -q "cn=accounts"; then
    ok "cn=accounts container exists"
  else
    fail "cn=accounts container missing (seed not applied?)"
  fi

  # Users subtree (at least 3 seeded users)
  user_result=$(ldapsearch -x -H ldap://localhost:389 \
    -D "${LDAP_BIND_DN}" -w "${LDAP_ADMIN_PASS}" \
    -b "${LDAP_USERS_DN}" "(objectClass=inetOrgPerson)" uid 2>/dev/null || true)
  user_count=$(echo "$user_result" | grep -c "^uid:" || true)
  info "Seeded users found: $user_count (expected ≥ 3)"
  if [[ "$user_count" -ge 3 ]]; then
    ok "Seeded users in ${LDAP_USERS_DN}: $user_count"
  else
    fail "Seeded users in ${LDAP_USERS_DN}: expected ≥ 3, got $user_count"
  fi

  # Groups subtree
  grp_result=$(ldapsearch -x -H ldap://localhost:389 \
    -D "${LDAP_BIND_DN}" -w "${LDAP_ADMIN_PASS}" \
    -b "${LDAP_GROUPS_DN}" "(objectClass=groupOfNames)" cn 2>/dev/null || true)
  grp_count=$(echo "$grp_result" | grep -c "^cn:" || true)
  info "Seeded groups found: $grp_count (expected ≥ 2)"
  if [[ "$grp_count" -ge 2 ]]; then
    ok "Seeded groups in ${LDAP_GROUPS_DN}: $grp_count"
  else
    fail "Seeded groups in ${LDAP_GROUPS_DN}: expected ≥ 2, got $grp_count"
  fi

  # Readonly bind (used by Keycloak federation)
  ro_result=$(ldapsearch -x -H ldap://localhost:389 \
    -D "${LDAP_READONLY_DN}" -w "${LDAP_ADMIN_PASS}" \
    -b "${LDAP_BASE}" -s base dn 2>/dev/null || true)
  if echo "$ro_result" | grep -q "${LDAP_BASE}"; then
    ok "OpenLDAP readonly bind succeeds"
  else
    fail "OpenLDAP readonly bind failed (Keycloak sync will fail)"
  fi
else
  ldap_open=$(nc -z localhost 389 2>/dev/null && echo "open" || echo "closed")
  if [[ "$ldap_open" == "open" ]]; then ok "OpenLDAP :389 port open (ldapsearch not available)"; else fail "OpenLDAP :389 port open"; fi
fi

# ─── Section 4: phpLDAPadmin ────────────────────────────────────────────────
section 4 "phpLDAPadmin :6443"
pla_status=$(curl -so /dev/null -w "%{http_code}" http://localhost:6443 2>/dev/null || echo "000")
info "phpLDAPadmin → HTTP $pla_status"
if [[ "$pla_status" == "200" || "$pla_status" == "301" || "$pla_status" == "302" ]]; then
  ok "phpLDAPadmin :6443 accessible"
else
  fail "phpLDAPadmin :6443 accessible (got $pla_status)"
fi

# ─── Section 5: Create realm + FreeIPA LDAP federation ────────────────────────
section 5 "Create realm '${REALM}' and FreeIPA-like LDAP federation"
if [[ -n "$token" ]]; then

  # 5a: Create realm (idempotent)
  realm_check=$(curl -sf "${KC_BASE}/admin/realms/${REALM}" \
    -H "Authorization: Bearer $token" 2>/dev/null | grep -o '"realm"' || true)
  if [[ -z "$realm_check" ]]; then
    curl -sf -X POST "${KC_BASE}/admin/realms" \
      -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
      -d "{\"realm\":\"${REALM}\",\"enabled\":true,\"displayName\":\"IT-Stack Integration Lab\"}" \
      2>/dev/null || true
    info "Realm ${REALM} created"
  else
    info "Realm ${REALM} already exists"
  fi
  realm_check2=$(curl -sf "${KC_BASE}/admin/realms/${REALM}" \
    -H "Authorization: Bearer $token" 2>/dev/null | grep -o '"realm"' || true)
  [[ -n "$realm_check2" ]] && ok "Realm '${REALM}' present" || fail "Realm '${REALM}' present"

  # 5b: Create LDAP federation component (FreeIPA-compatible DN paths; vendor=other for OpenLDAP)
  existing_comps=$(curl -sf \
    "${KC_BASE}/admin/realms/${REALM}/components?type=org.keycloak.storage.UserStorageProvider" \
    -H "Authorization: Bearer $token" 2>/dev/null || true)
  if echo "$existing_comps" | grep -q '"freeipa-ldap-sim"'; then
    info "LDAP federation component 'freeipa-ldap-sim' already exists"
  else
    curl -sf -X POST "${KC_BASE}/admin/realms/${REALM}/components" \
      -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
      -d "{
        \"name\":\"freeipa-ldap-sim\",
        \"providerId\":\"ldap\",
        \"providerType\":\"org.keycloak.storage.UserStorageProvider\",
        \"config\":{
          \"vendor\":[\"rhds\"],
          \"connectionUrl\":[\"ldap://openldap:389\"],
          \"bindDn\":[\"${LDAP_READONLY_DN}\"],
          \"bindCredential\":[\"${LDAP_ADMIN_PASS}\"],
          \"usersDn\":[\"${LDAP_USERS_DN}\"],
          \"usernameLDAPAttribute\":[\"uid\"],
          \"rdnLDAPAttribute\":[\"uid\"],
          \"uuidLDAPAttribute\":[\"entryUUID\"],
          \"userObjectClasses\":[\"inetOrgPerson, organizationalPerson\"],
          \"importEnabled\":[\"true\"],
          \"syncRegistrations\":[\"false\"],
          \"enabled\":[\"true\"],
          \"priority\":[\"0\"],
          \"fullSyncPeriod\":[\"-1\"],
          \"changedSyncPeriod\":[\"-1\"]
        }
      }" 2>/dev/null || true
    info "LDAP federation component 'freeipa-ldap-sim' created"
  fi

  # Get component ID
  comp_json=$(curl -sf \
    "${KC_BASE}/admin/realms/${REALM}/components?type=org.keycloak.storage.UserStorageProvider" \
    -H "Authorization: Bearer $token" 2>/dev/null || true)
  fed_id=$(echo "$comp_json" | python3 -c \
    "import sys,json; comps=json.load(sys.stdin); \
     ids=[c['id'] for c in comps if c.get('name')=='freeipa-ldap-sim']; \
     print(ids[0] if ids else '')" 2>/dev/null || true)
  info "Federation component ID: '${fed_id}'"
  [[ -n "$fed_id" ]] && ok "Federation component ID retrieved" || fail "Federation component ID retrieved"

  # 5c: Add group mapper (idempotent)
  if [[ -n "$fed_id" ]]; then
    existing_mappers=$(curl -sf \
      "${KC_BASE}/admin/realms/${REALM}/components?parent=${fed_id}&type=org.keycloak.storage.ldap.mappers.LDAPStorageMapper" \
      -H "Authorization: Bearer $token" 2>/dev/null || true)
    if echo "$existing_mappers" | grep -q '"group-ldap-mapper"'; then
      info "Group mapper already exists"
    else
      curl -sf -X POST "${KC_BASE}/admin/realms/${REALM}/components" \
        -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
        -d "{
          \"name\":\"group-ldap-mapper\",
          \"providerId\":\"group-ldap-mapper\",
          \"providerType\":\"org.keycloak.storage.ldap.mappers.LDAPStorageMapper\",
          \"parentId\":\"${fed_id}\",
          \"config\":{
            \"groups.dn\":[\"${LDAP_GROUPS_DN}\"],
            \"group.name.ldap.attribute\":[\"cn\"],
            \"group.object.classes\":[\"groupOfNames\"],
            \"preserve.group.inheritance\":[\"true\"],
            \"membership.ldap.attribute\":[\"member\"],
            \"membership.attribute.type\":[\"DN\"],
            \"membership.user.ldap.attribute\":[\"uid\"],
            \"groups.ldap.filter\":[\"\"],
            \"mode\":[\"READ_ONLY\"],
            \"user.roles.retrieve.strategy\":[\"LOAD_GROUPS_BY_MEMBER_ATTRIBUTE\"],
            \"drop.non.existing.groups.during.sync\":[\"false\"],
            \"ignore.missing.groups\":[\"true\"]
          }
        }" 2>/dev/null || true
      info "Group mapper created"
    fi
    grp_mapper_check=$(curl -sf \
      "${KC_BASE}/admin/realms/${REALM}/components?parent=${fed_id}&type=org.keycloak.storage.ldap.mappers.LDAPStorageMapper" \
      -H "Authorization: Bearer $token" 2>/dev/null | grep -c '"group-ldap-mapper"' || true)
    [[ "$grp_mapper_check" -ge 1 ]] && ok "Group mapper present" || fail "Group mapper present"
  else
    fail "Group mapper (skipped: no federation ID)"
  fi

  # 5d: Trigger full LDAP sync
  if [[ -n "$fed_id" ]]; then
    sync_resp=$(curl -sf -X POST \
      "${KC_BASE}/admin/realms/${REALM}/user-storage/${fed_id}/sync?action=triggerFullSync" \
      -H "Authorization: Bearer $token" 2>/dev/null || true)
    info "Sync response: ${sync_resp:0:160}"
    if echo "$sync_resp" | python3 -c \
        "import sys,json; r=json.load(sys.stdin); exit(0 if r.get('added',0)+r.get('updated',0)>0 else 1)" \
        2>/dev/null; then
      synced=$(echo "$sync_resp" | python3 -c \
        "import sys,json; r=json.load(sys.stdin); print(r.get('added',0)+r.get('updated',0))" 2>/dev/null || echo "?")
      ok "Full LDAP sync completed: $synced users synced"
    else
      fail "Full LDAP sync: no added/updated users reported"
    fi

    # 5e: Wait for sync, then assert federationLink on users
    info "Waiting ${SYNC_WAIT}s for sync to settle..."
    sleep "$SYNC_WAIT"
    users_json=$(curl -sf \
      "${KC_BASE}/admin/realms/${REALM}/users?max=100" \
      -H "Authorization: Bearer $token" 2>/dev/null || true)
    fed_link_count=$(echo "$users_json" | python3 -c \
      "import sys,json; us=json.load(sys.stdin); \
       print(sum(1 for u in us if 'federationLink' in u))" 2>/dev/null || echo "0")
    info "Users with federationLink: $fed_link_count"
    if [[ "$fed_link_count" -ge 3 ]]; then
      ok "Synced users have federationLink: $fed_link_count"
    else
      fail "Users with federationLink: expected ≥ 3, got $fed_link_count"
    fi

    # 5f: Assert testadmin exists as a synced user
    admin_user=$(curl -sf \
      "${KC_BASE}/admin/realms/${REALM}/users?username=testadmin" \
      -H "Authorization: Bearer $token" 2>/dev/null || true)
    if echo "$admin_user" | grep -q '"testadmin"'; then
      ok "testadmin synced into Keycloak"
    else
      fail "testadmin synced into Keycloak"
    fi

    # 5g: Assert cn=admins group synced
    kc_groups=$(curl -sf "${KC_BASE}/admin/realms/${REALM}/groups" \
      -H "Authorization: Bearer $token" 2>/dev/null || true)
    if echo "$kc_groups" | grep -q '"admins"'; then
      ok "Group 'admins' synced from LDAP"
    else
      fail "Group 'admins' synced from LDAP"
    fi
  else
    fail "LDAP sync (skipped: no federation ID)"
    fail "federationLink check (skipped)"
    fail "testadmin sync (skipped)"
    fail "admins group sync (skipped)"
  fi
else
  fail "Federation setup (no admin token)"
fi

# ─── Section 6: OIDC clients app-a and app-b ───────────────────────────────────
section 6 "Create OIDC clients app-a and app-b"
if [[ -n "$token" ]]; then
  for client in "app-a" "app-b"; do
    curl -sf -X POST "${KC_BASE}/admin/realms/${REALM}/clients" \
      -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
      -d "{\"clientId\":\"${client}\",\"publicClient\":false,\"protocol\":\"openid-connect\",\"enabled\":true,\"serviceAccountsEnabled\":true}" \
      2>/dev/null || true
  done
  client_count=$(curl -sf "${KC_BASE}/admin/realms/${REALM}/clients" \
    -H "Authorization: Bearer $token" 2>/dev/null | grep -o '"clientId"' | wc -l | tr -d ' ' || echo 0)
  info "Clients in realm ${REALM}: $client_count"
  if [[ "$client_count" -ge 2 ]]; then ok "OIDC clients app-a and app-b created"; else fail "OIDC clients app-a and app-b (found $client_count)"; fi
fi

# ─── Section 7: Client credentials flow (app-a) ───────────────────────────────
section 7 "Client credentials flow — app-a"
if [[ -n "$token" ]]; then
  client_uuid=$(curl -sf "${KC_BASE}/admin/realms/${REALM}/clients?clientId=app-a" \
    -H "Authorization: Bearer $token" 2>/dev/null | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
  info "app-a UUID: $client_uuid"
  if [[ -n "$client_uuid" ]]; then
    secret=$(curl -sf -X POST \
      "${KC_BASE}/admin/realms/${REALM}/clients/${client_uuid}/client-secret" \
      -H "Authorization: Bearer $token" 2>/dev/null | grep -o '"value":"[^"]*"' | cut -d'"' -f4 || true)
    if [[ -n "$secret" ]]; then
      app_token=$(curl -sf -X POST \
        "${KC_BASE}/realms/${REALM}/protocol/openid-connect/token" \
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

# ─── Section 8: OIDC discovery ────────────────────────────────────────────────
section 8 "OIDC discovery for realm '${REALM}'"
discovery=$(curl -sf "${KC_BASE}/realms/${REALM}/.well-known/openid-configuration" 2>/dev/null || true)
required=("issuer" "authorization_endpoint" "token_endpoint" "jwks_uri" "userinfo_endpoint")
disc_pass=0
for field in "${required[@]}"; do
  echo "$discovery" | grep -q "\"${field}\"" && ((disc_pass++)) || true
done
info "OIDC discovery fields present: $disc_pass/5"
if [[ "$disc_pass" -ge 5 ]]; then ok "OIDC discovery has all 5 required fields"; else fail "OIDC discovery fields ($disc_pass/5)"; fi

# ─── Section 9: SAML 2.0 descriptor ────────────────────────────────────────────
section 9 "SAML 2.0 descriptor endpoint"
saml_status=$(curl -so /dev/null -w "%{http_code}" \
  "${KC_BASE}/realms/${REALM}/protocol/saml/descriptor" 2>/dev/null || echo "000")
if [[ "$saml_status" == "200" ]]; then ok "SAML 2.0 descriptor available"; else fail "SAML 2.0 descriptor (got $saml_status)"; fi

# ─── Section 10: MailHog ────────────────────────────────────────────────────────
section 10 "MailHog :8025"
mh_status=$(curl -so /dev/null -w "%{http_code}" http://localhost:8025 2>/dev/null || echo "000")
info "MailHog → HTTP $mh_status"
if [[ "$mh_status" == "200" ]]; then ok "MailHog :8025 accessible"; else fail "MailHog :8025 accessible (got $mh_status)"; fi
mh_api=$(curl -sf "http://localhost:8025/api/v2/messages" 2>/dev/null | grep -c '"items"' || echo 0)
if [[ "$mh_api" -ge 1 ]]; then ok "MailHog API /api/v2/messages responds"; else fail "MailHog API /api/v2/messages"; fi

# ─── Section 11: App service ports ─────────────────────────────────────────────
section 11 "App services :9001 and :9002"
for port in 9001 9002; do
  st=$(curl -so /dev/null -w "%{http_code}" "http://localhost:${port}" 2>/dev/null || echo "000")
  if [[ "$st" == "200" ]]; then ok "App :${port} → 200"; else fail "App :${port} → 200 (got $st)"; fi
done

# ─── Section 12: Realm count ──────────────────────────────────────────────────
section 12 "Realm list (master + ${REALM})"
if [[ -n "$token" ]]; then
  realm_count=$(curl -sf "${KC_BASE}/admin/realms" \
    -H "Authorization: Bearer $token" 2>/dev/null | grep -o '"realm"' | wc -l | tr -d ' ' || echo 0)
  info "Realms found: $realm_count"
  if [[ "$realm_count" -ge 2 ]]; then ok "At least 2 realms (master + ${REALM})"; else fail "At least 2 realms (found $realm_count)"; fi
fi

# ─── Section 13: Final score ────────────────────────────────────────────────────
section 13 "Final score"
TOTAL=$((PASS + FAIL))
echo ""
echo "Results: $PASS passed / $FAIL failed / $TOTAL total"
echo ""
if [[ $FAIL -eq 0 ]]; then
  echo "╔══════════════════════════════════════════════╗"
  echo "║  ALL CHECKS PASSED — INT-01 FreeIPA↔KC OK   ║"
  echo "╚══════════════════════════════════════════════╝"
  exit 0
else
  echo "╔══════════════════════════════════════════════╗"
  printf  "║  FAILED: %-3d check(s) did not pass          ║\n" "$FAIL"
  echo "╚══════════════════════════════════════════════╝"
  exit 1
fi

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
