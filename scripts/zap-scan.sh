#!/bin/sh
# ZAP Baseline scan against a RUNNING deployment - used as the production security smoke test.
#   usage: zap-scan.sh <namespace> <service> <local-port> [report-file]
set -eu

NS=${1:?namespace required}
SVC=${2:?service required}
LP=${3:?local port required}
REPORT=${4:-zap-report.html}
API="http://localhost:${LP}/timesheet-devops/user"
VOL=$(docker inspect jenkins --format '{{range .Mounts}}{{if eq .Destination "/var/jenkins_home"}}{{.Name}}{{end}}{{end}}')
PF=0

echo "=== ZAP BASELINE SMOKE TEST: namespace=$NS service=$SVC port=$LP ==="

k=0
until [ -n "$(kubectl -n "$NS" get endpoints "$SVC" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)" ]; do
    k=$((k+1))
    if [ $k -ge 30 ]; then echo "FAIL: service $SVC has no ready endpoint"; exit 1; fi
    sleep 2
done

pkill -f "port-forward svc/${SVC}" 2>/dev/null || true
start_pf() {
    kubectl -n "$NS" port-forward "svc/${SVC}" "${LP}:8080" >> /tmp/zap-scan-pf.log 2>&1 &
    PF=$!
}
start_pf
trap 'kill $PF 2>/dev/null || true' EXIT
i=0
until curl -s -o /dev/null -m 2 "$API/retrieve-all-users"; do
    if ! kill -0 "$PF" 2>/dev/null; then echo 'port-forward died, restarting...'; start_pf; fi
    i=$((i+1))
    if [ $i -ge 45 ]; then echo "FAIL: app not reachable at $API"; cat /tmp/zap-scan-pf.log; exit 1; fi
    sleep 2
done
echo "app reachable (port-forward pid=$PF)"

docker run --rm --network container:jenkins --mount type=volume,src=$VOL,dst=/zap/wrk \
    zaproxy/zap-stable:2.17.0 zap-baseline.py -t "$API/retrieve-all-users" \
    -r zap-report.html -m 1 -I -s
mv -f /var/jenkins_home/zap-report.html "$WORKSPACE/$REPORT"
echo "smoke test report: $REPORT"
