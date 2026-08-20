#!/bin/sh
# Boot the inner Docker daemon, then the app. Nothing in Loopyard works before
# dockerd is answering, so this blocks until it is — or dies loudly.
set -eu

DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-/data/docker}"
LOOPYARD_HOME="${LOOPYARD_HOME:-/data/loopyard}"
mkdir -p "$DOCKER_DATA_ROOT" "$LOOPYARD_HOME"

dockerd \
  --host=unix:///var/run/docker.sock \
  --data-root="$DOCKER_DATA_ROOT" \
  --storage-driver=overlay2 \
  >/var/log/dockerd.log 2>&1 &
dockerd_pid=$!

waited=0
until docker info >/dev/null 2>&1; do
  kill -0 "$dockerd_pid" 2>/dev/null || {
    echo "dockerd exited during startup:" >&2
    tail -n 50 /var/log/dockerd.log >&2
    exit 1
  }
  waited=$((waited + 1))
  if [ "$waited" -gt 60 ]; then
    echo "dockerd did not become ready in 60s:" >&2
    tail -n 50 /var/log/dockerd.log >&2
    exit 1
  fi
  sleep 1
done
echo "[entrypoint] dockerd ready ($(docker info --format '{{.Driver}}') on $(uname -r))"

# The spike: prove the inner daemon can publish a port before trusting the
# platform with a real workspace. LOOPYARD_DIND_PROBE=1 runs it and exits.
if [ "${LOOPYARD_DIND_PROBE:-0}" = "1" ]; then
  exec /usr/local/bin/dind-probe.sh
fi

exec /app/bin/loopyard start
