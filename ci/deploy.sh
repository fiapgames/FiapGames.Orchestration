#!/usr/bin/env bash
# Aplica os manifestos de um serviço trocando a imagem e espera o rolling update.
# É o mesmo passo de deploy no EKS (pipeline) e no Kind (aws-local/up.sh, ci/simulate-pipeline.sh):
# no primeiro deploy cria tudo, nos seguintes só troca a imagem.
#
#   ci/deploy.sh <pasta-k8s> <imagem-nos-manifestos> <imagem-nova>
#   ci/deploy.sh ../Fiap.Games.Users/k8s user-games-fiap:latest 123.dkr.ecr.../fiapgames/users-api:abc123
#
# KUBE_CONTEXT escolhe o cluster; sem ele, usa o contexto atual.
set -euo pipefail
shopt -s inherit_errexit

[ $# -eq 3 ] || { sed -n '2,8p' "$0"; exit 1; }
MANIFESTS="$1"
PLACEHOLDER="$2"
IMAGE="$3"
NAMESPACE="${NAMESPACE:-fiapgames}"

kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

files=()
for f in "$MANIFESTS"/*.yaml; do
  # No EKS a pipeline só edita dentro do namespace; quem cria o namespace é a infra.
  grep -q '^kind: Namespace' "$f" && grep -c '^kind:' "$f" | grep -qx 1 && continue
  files+=("$f")
done
[ ${#files[@]} -gt 0 ] || { echo "nenhum manifesto em $MANIFESTS" >&2; exit 1; }
grep -q "image: ${PLACEHOLDER}" "${files[@]}" || { echo "imagem '$PLACEHOLDER' não aparece em $MANIFESTS" >&2; exit 1; }

# Job tem template imutável: com imagem nova ele precisa ser recriado.
for f in "${files[@]}"; do
  grep -q '^kind: Job' "$f" && kctl delete -f "$f" --ignore-not-found --wait=true
done

applied="$(for f in "${files[@]}"; do sed "s#image: ${PLACEHOLDER}#image: ${IMAGE}#" "$f"; printf '\n---\n'; done |
  kctl apply -n "$NAMESPACE" -f - -o name)"
echo "$applied"

for obj in $applied; do
  case "$obj" in
    job.batch/*) kctl wait -n "$NAMESPACE" --for=condition=complete "$obj" --timeout=300s ;;
  esac
done
for obj in $applied; do
  case "$obj" in
    deployment.apps/*) kctl rollout status -n "$NAMESPACE" "$obj" --timeout=600s ;;
  esac
done
