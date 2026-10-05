#!/bin/sh
# Configuration Safety Check: fail if the LIVE configuration deviates from what git declares.
#   usage: config-safety-check.sh <expected-image> <staging-ns> <production-ns>
# Expected values mirror k8s/*.yaml (replicas: 2, nodePorts 30007/30008, ClusterIP mysql).
set -u

IMG=${1:?expected image required}
STAGING_NS=${2:?staging namespace required}
PROD_NS=${3:?production namespace required}
FAILED=0

pass() { echo "  PASS: $1"; }
fail() { FAILED=1; echo "  FAIL: $1"; }

check_deployment() {
    ns=$1
    echo "--- deployment timesheet-dep [$ns] ---"
    kubectl -n "$ns" get deployment timesheet-dep -o wide || { fail "$ns deployment missing"; return; }
    img=$(kubectl -n "$ns" get deployment timesheet-dep -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
    if [ "$img" = "$IMG" ]; then pass "$ns runs the expected image $IMG"; else fail "$ns image is '$img' (expected $IMG)"; fi
    want=$(kubectl -n "$ns" get deployment timesheet-dep -o jsonpath='{.spec.replicas}' 2>/dev/null)
    have=$(kubectl -n "$ns" get deployment timesheet-dep -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
    if [ "$want" = "2" ]; then pass "$ns declared replicas = 2 (as in git)"; else fail "$ns declared replicas = '$want' (git declares 2)"; fi
    if [ "${have:-0}" = "$want" ] && [ -n "$want" ]; then pass "$ns available replicas = $have/$want"; else fail "$ns available replicas = '${have:-0}/$want' - workload not fully available"; fi
}

check_service() {
    ns=$1
    expected_np=$2
    echo "--- service timesheet-service [$ns] ---"
    kubectl -n "$ns" get service timesheet-service -o wide || { fail "$ns service missing"; return; }
    type=$(kubectl -n "$ns" get service timesheet-service -o jsonpath='{.spec.type}' 2>/dev/null)
    if [ "$type" = "NodePort" ]; then pass "$ns service type = NodePort"; else fail "$ns service type is '$type'"; fi
    live_np=$(kubectl -n "$ns" get service timesheet-service -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
    if [ "$live_np" = "$expected_np" ]; then pass "$ns nodePort = $expected_np (as in git)"; else fail "$ns nodePort = '$live_np' (git declares $expected_np)"; fi
}

check_database_not_exposed() {
    ns=$1
    type=$(kubectl -n "$ns" get service mysql -o jsonpath='{.spec.type}' 2>/dev/null)
    if [ "$type" = "ClusterIP" ]; then pass "$ns mysql is ClusterIP - not reachable from outside the cluster"; else fail "$ns mysql service type is '$type' (must be ClusterIP)"; fi
}

check_secret_material() {
    ns=$1
    if kubectl -n "$ns" get secret timesheet-secret > /dev/null 2>&1; then pass "$ns secret timesheet-secret present"; else fail "$ns secret timesheet-secret missing"; fi
    if kubectl -n "$ns" get configmap timesheet-config > /dev/null 2>&1; then pass "$ns configmap timesheet-config present"; else fail "$ns configmap timesheet-config missing"; fi
}

check_deployment "$STAGING_NS"
check_service "$STAGING_NS" 30007
check_deployment "$PROD_NS"
check_service "$PROD_NS" 30008
check_database_not_exposed "$STAGING_NS"
check_database_not_exposed "$PROD_NS"
check_secret_material "$STAGING_NS"
check_secret_material "$PROD_NS"

echo "======================================"
if [ "$FAILED" -eq 0 ]; then
    echo 'CONFIG SAFETY CHECK: PASS - live configuration matches the git baseline'
    exit 0
fi
echo 'CONFIG SAFETY CHECK: DEVIATION DETECTED - fix before release'
exit 1
