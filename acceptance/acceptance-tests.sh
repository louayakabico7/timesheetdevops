#!/bin/sh
# ---------------------------------------------------------------------------
# Acceptance tests: black-box business checks against a RUNNING deployment.
#
#   usage: acceptance-tests.sh [namespace] [service] [local-port]
#     e.g. acceptance-tests.sh chap4-khadijabenjaafar-4nids3 timesheet-service 30009
#
# Business contract tested (/timesheet-devops/user):
#   1. list users        GET    /retrieve-all-users    -> 200
#   2. create user       POST   /add-user              -> 200 + numeric id
#   3. read back         GET    /retrieve-user/{id}    -> 200 + created data
#   4. modify user       PUT    /modify-user           -> 200 + updated data
#   5. delete user       DELETE /remove-user/{id}       -> 200
#   6. verify deletion   GET    /retrieve-user/{id}    -> 200 + empty body
#
# Self-contained: creates its own kubectl port-forward, waits for the app,
# runs the checks, then tears the port-forward down.
# Exit code: 0 = accepted, 1 = rejected.
# ---------------------------------------------------------------------------
set -u

NS=${1:-chap4-khadijabenjaafar-4nids3}
SVC=${2:-timesheet-service}
LP=${3:-30009}
API="http://localhost:${LP}/timesheet-devops/user"
BODY_FILE=$(mktemp)
PF=0
PASSED=0
FAILED=0
CODE=000
BODY=''

echo "=== ACCEPTANCE TESTS: namespace=$NS service=$SVC url=$API ==="

# --- reachability ---------------------------------------------------------
k=0
until [ -n "$(kubectl -n "$NS" get endpoints "$SVC" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)" ]; do
    k=$((k+1))
    if [ $k -ge 30 ]; then echo "FAIL: service $SVC has no ready endpoint"; exit 1; fi
    sleep 2
done

pkill -f "port-forward svc/${SVC}" 2>/dev/null || true
start_pf() {
    kubectl -n "$NS" port-forward "svc/${SVC}" "${LP}:8080" >> /tmp/acc-pf.log 2>&1 &
    PF=$!
}
start_pf
trap 'kill $PF 2>/dev/null || true; rm -f "$BODY_FILE"' EXIT
i=0
until curl -s -o /dev/null -m 2 "$API/retrieve-all-users"; do
    if ! kill -0 "$PF" 2>/dev/null; then echo 'port-forward died, restarting...'; start_pf; fi
    i=$((i+1))
    if [ $i -ge 45 ]; then echo "FAIL: app not reachable at $API"; cat /tmp/acc-pf.log; exit 1; fi
    sleep 2
done
echo "app reachable (port-forward pid=$PF)"

# --- helpers --------------------------------------------------------------
req() {
    if [ "$#" -ge 3 ]; then
        CODE=$(curl -s -o "$BODY_FILE" -w '%{http_code}' -X "$1" -H 'Content-Type: application/json' -d "$3" -m 15 "$2")
    else
        CODE=$(curl -s -o "$BODY_FILE" -w '%{http_code}' -X "$1" -m 15 "$2")
    fi
    BODY=$(cat "$BODY_FILE")
}
pass() { PASSED=$((PASSED+1)); echo "  PASS: $1"; }
fail() { FAILED=$((FAILED+1)); echo "  FAIL: $1"; }
expect_code() {
    if [ "$CODE" = "$1" ]; then pass "$2 -> HTTP $CODE"; else fail "$2 -> expected HTTP $1, got $CODE; body [$BODY]"; fi
}
expect_contains() {
    case "$BODY" in
        *"$1"*) pass "$2" ;;
        *) fail "$2 -> expected [$1] in body [$BODY]" ;;
    esac
}
expect_empty() {
    if [ -z "$BODY" ]; then pass "$2"; else fail "$2 -> expected empty body, got [$BODY]"; fi
}

# --- the checks -----------------------------------------------------------
echo '  1) list users'
req GET "$API/retrieve-all-users"
expect_code 200 'GET /retrieve-all-users'

echo '  2) create user'
req POST "$API/add-user" '{"lastName":"AcceptancePipeline"}'
expect_code 200 'POST /add-user'
ID=$(printf '%s' "$BODY" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
if [ -n "$ID" ]; then pass "created user with id=$ID"; else fail "add-user returned no numeric id; body [$BODY]"; fi

if [ -n "$ID" ]; then
    echo '  3) read the created user'
    req GET "$API/retrieve-user/$ID"
    expect_code 200 'GET /retrieve-user/{id}'
    expect_contains '"lastName":"AcceptancePipeline"' 'read returns the created data'

    echo '  4) modify the user'
    req PUT "$API/modify-user" "{\"id\":${ID},\"lastName\":\"AcceptedByPipeline\"}"
    expect_code 200 'PUT /modify-user'
    expect_contains '"lastName":"AcceptedByPipeline"' 'update is persisted'

    echo '  5) delete the user'
    req DELETE "$API/remove-user/$ID"
    expect_code 200 'DELETE /remove-user/{id}'

    echo '  6) verify the deletion'
    req GET "$API/retrieve-user/$ID"
    expect_code 200 'GET /retrieve-user/{id} after delete'
    expect_empty 'deleted user returns no data'
else
    fail 'steps 3-6 skipped: create returned no id'
fi

echo '======================================'
echo "ACCEPTANCE RESULT: $PASSED passed, $FAILED failed"
if [ "$FAILED" -eq 0 ]; then
    echo 'ACCEPTANCE: SUCCESS - business contract verified'
    exit 0
fi
echo 'ACCEPTANCE: FAILURE - do not promote this build'
exit 1
