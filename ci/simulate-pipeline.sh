#!/usr/bin/env bash
# Roda localmente os mesmos passos do workflow de CI/CD, com o Kind no lugar do
# EKS e o registry local no lugar do ECR. Exige o ambiente de aws-local/up.sh de pé.
#
#   ci/simulate-pipeline.sh catalog-api
#   ci/simulate-pipeline.sh users-api
set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true  # bash < 4.4 (macOS) não tem

REGISTRY=localhost:5001
TRIVY_IMAGE=aquasec/trivy:0.75.0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$(cd "$ROOT/.." && pwd)"
# shellcheck source=services.sh
. "$ROOT/ci/services.sh"

svc=""
for entry in "${SERVICES[@]}"; do
  [ "${entry%%|*}" = "${1:-}" ] && svc="$entry"
done
[ -n "$svc" ] || { sed -n '2,6p' "$0"; exit 1; }
IFS='|' read -r name repo context solution placeholder <<<"$svc"
REPO="$WORKSPACE/$repo"

step() { printf '\n==> %s\n' "$*"; }

IMAGE="${REGISTRY}/fiapgames/${name}:$(image_tag "$REPO")"

step "Build & Test"
dotnet test "$REPO/$solution" -c Release

step "Containerização: ${IMAGE}"
docker build -t "$IMAGE" "$REPO/$context"

step "Security scan (Trivy, só relatório)"
MSYS_NO_PATHCONV=1 docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  -v trivy-cache:/root/.cache "$TRIVY_IMAGE" image --no-progress --severity HIGH,CRITICAL --ignore-unfixed "$IMAGE"

step "Push"
docker push "$IMAGE"

step "Deploy (rolling update)"
KUBE_CONTEXT=kind-fiapgames "$ROOT/ci/deploy.sh" "$REPO/k8s" "$placeholder" "$IMAGE"
