#!/bin/sh
# Does the inner daemon actually work — build, run, and above all PUBLISH?
#
# Port publishing is the one that can fail silently on a locked-down host:
# dockerd starts, containers run, and -p is a no-op because it can't program
# iptables. Loopyard's entire port model (PortRegistry, probe_http, app_url)
# rests on it, so this is the go/no-go for a platform.
set -u

fail=0
check() {
  if [ "$1" = "0" ]; then echo "  ok    $2"; else echo "  FAIL  $2"; fail=1; fi
}

echo "[probe] daemon"
docker info >/dev/null 2>&1; check $? "docker info"
echo "        storage driver: $(docker info --format '{{.Driver}}' 2>/dev/null)"
echo "        kernel:         $(uname -r)"

echo "[probe] iptables"
iptables -t nat -L DOCKER >/dev/null 2>&1; check $? "nat table has DOCKER chain"

echo "[probe] pull + run + publish"
docker rm -f loopyard-probe >/dev/null 2>&1
docker run -d --name loopyard-probe -p 18080:80 nginx:alpine >/dev/null 2>&1
check $? "run -d -p 18080:80 nginx:alpine"

i=0
until curl -sf -o /dev/null http://127.0.0.1:18080; do
  i=$((i + 1))
  [ "$i" -gt 20 ] && break
  sleep 1
done
curl -sf -o /dev/null http://127.0.0.1:18080; check $? "published port reachable on 127.0.0.1:18080"

echo "[probe] named volume"
docker volume create loopyard-probe-vol >/dev/null 2>&1
docker run --rm -v loopyard-probe-vol:/v alpine sh -c 'echo hi > /v/f && cat /v/f' >/dev/null 2>&1
check $? "write/read through a named volume"

echo "[probe] cleanup"
docker rm -f loopyard-probe >/dev/null 2>&1
docker volume rm loopyard-probe-vol >/dev/null 2>&1

if [ "$fail" = "0" ]; then
  echo "[probe] PASS — this host can run Loopyard's container model"
else
  echo "[probe] FAIL — see above; do not deploy Loopyard here yet"
fi
exit "$fail"
