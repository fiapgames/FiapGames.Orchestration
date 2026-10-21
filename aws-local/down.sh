#!/usr/bin/env bash
# Derruba o ambiente local da AWS. O registry fica de pé para reaproveitar o
# cache das imagens; KEEP_REGISTRY=0 remove ele também.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CPK_PID="$HERE/.bin/cloud-provider-kind.pid"

if [ -f "$CPK_PID" ]; then
  kill "$(cat "$CPK_PID")" 2>/dev/null || true
  rm -f "$CPK_PID"
fi

kind delete cluster --name fiapgames
# Containers Envoy que o cloud-provider-kind cria para cada Service LoadBalancer.
docker ps -aq --filter "name=kindccm" | xargs -r docker rm -f >/dev/null

if [ "${KEEP_REGISTRY:-1}" = "0" ]; then
  docker rm -f kind-registry >/dev/null 2>&1 || true
  rm -f "$HERE/.tags"
fi
