#!/usr/bin/env bash
# Diz se o ambiente está ocioso: nenhuma requisição pelo Kong e nenhum deploy
# nos últimos N minutos. Health checks não contam, senão uma aba esquecida no
# navegador manteria tudo ligado. O estado fica num ConfigMap do próprio cluster.
#
#   ci/idle-check.sh check 60   # sai com 10 se está ocioso há 60 min ou mais
#   ci/idle-check.sh touch      # zera o contador de ociosidade (manter ligado)
#
# KUBE_CONTEXT escolhe o cluster; sem ele, usa o contexto atual.
set -euo pipefail
shopt -s inherit_errexit

NAMESPACE="${NAMESPACE:-fiapgames}"
STATE=auto-off
kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

proxied_requests() {
  local metrics
  metrics="$(kctl get --raw "/api/v1/namespaces/${NAMESPACE}/services/kong:8100/proxy/metrics" 2>/dev/null)" || return 1
  awk '/^kong_http_requests_total/ && !/route="[^"]*health[^"]*"/ { sum += $NF } END { printf "%d\n", sum }' <<<"$metrics"
}

latest_deploy() {
  local newest
  newest="$(kctl get replicasets -n "$NAMESPACE" \
    -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{"\n"}{end}' | sort | tail -1)"
  [ -n "$newest" ] && date -d "$newest" +%s || echo 0
}

save_state() {
  kctl create configmap "$STATE" -n "$NAMESPACE" \
    --from-literal=requests="$1" --from-literal=lastActivity="$2" \
    --dry-run=client -o yaml | kctl apply -f - >/dev/null
}

now="$(date +%s)"
# Kong ainda subindo ou fora do ar: sem leitura, não conta como uso.
requests="$(proxied_requests || echo "?")"

case "${1:-}" in
  touch)
    save_state "$requests" "$now"
    echo "contador de ociosidade zerado"
    ;;
  check)
    limit=$(( ${2:?informe os minutos} * 60 ))
    last_requests="$(kctl get configmap "$STATE" -n "$NAMESPACE" -o jsonpath='{.data.requests}' 2>/dev/null || true)"
    last_activity="$(kctl get configmap "$STATE" -n "$NAMESPACE" -o jsonpath='{.data.lastActivity}' 2>/dev/null || true)"
    # Sem estado gravado nem leitura do Kong não há como medir; quem chamou decide.
    [ -z "$last_activity" ] && [ "$requests" = "?" ] && { echo "uso não medido"; exit 2; }
    if [ -z "$last_activity" ] ||
      { [ "$requests" != "?" ] && [ "$requests" != "$last_requests" ]; } ||
      [ "$(latest_deploy)" -gt "$last_activity" ]; then
      save_state "$requests" "$now"
      last_activity="$now"
    fi
    idle=$(( now - last_activity ))
    echo "requisições: ${requests} · ocioso há $(( idle / 60 )) min · limite $(( limit / 60 )) min"
    [ "$idle" -ge "$limit" ] && exit 10
    exit 0
    ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
