#!/usr/bin/env bash
# Sobe o ambiente local que espelha a AWS: Kind (EKS), registry (ECR),
# cloud-provider-kind (load balancer) e OpenSearch (Amazon OpenSearch Service).
# Idempotente: rodar de novo rebuilda as imagens e faz rolling update.
#
#   ./aws-local/up.sh                # tudo
#   SKIP_BUILD=1 ./aws-local/up.sh   # reaplica sem rebuildar as imagens
#   KIND_CONFIG=outro.yaml ./aws-local/up.sh   # se a porta 8000 do host estiver ocupada
set -euo pipefail
shopt -s inherit_errexit

# No Git Bash, caminhos de dentro do container (/etc/...) não podem virar C:/Program Files/Git/...
in_container() { MSYS_NO_PATHCONV=1 "$@"; }

CLUSTER=fiapgames
NAMESPACE=fiapgames
REGISTRY_NAME=kind-registry
REGISTRY_PORT=5001
REGISTRY="localhost:${REGISTRY_PORT}"
CPK_VERSION=v0.12.0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$(cd "$ROOT/.." && pwd)"
BIN_DIR="$ROOT/aws-local/.bin"
CPK_PID="$BIN_DIR/cloud-provider-kind.pid"
cd "$ROOT"

step() { printf '\n==> %s\n' "$*"; }

for bin in docker kind kubectl git curl tar; do
  command -v "$bin" >/dev/null || { echo "faltando: $bin" >&2; exit 1; }
done

step "Registry local (papel do ECR) em ${REGISTRY}"
if [ "$(docker inspect -f '{{.State.Running}}' "$REGISTRY_NAME" 2>/dev/null || true)" != "true" ]; then
  docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true
  docker run -d --restart=always -p "127.0.0.1:${REGISTRY_PORT}:5000" --name "$REGISTRY_NAME" registry:2 >/dev/null
fi

step "Cluster Kind '${CLUSTER}' (papel do EKS)"
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind create cluster --config "${KIND_CONFIG:-kind-config.yaml}"
fi
kubectl config use-context "kind-${CLUSTER}" >/dev/null

# Dentro do node, localhost:5001 precisa apontar para o container do registry.
for node in $(kind get nodes --name "$CLUSTER"); do
  in_container docker exec "$node" mkdir -p "/etc/containerd/certs.d/${REGISTRY}"
  printf '[host."http://%s:5000"]\n' "$REGISTRY_NAME" |
    in_container docker exec -i "$node" cp /dev/stdin "/etc/containerd/certs.d/${REGISTRY}/hosts.toml"
done
if [ "$(docker inspect -f '{{json .NetworkSettings.Networks.kind}}' "$REGISTRY_NAME")" = "null" ]; then
  docker network connect kind "$REGISTRY_NAME"
fi
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "${REGISTRY}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

step "cloud-provider-kind (papel do AWS Load Balancer)"
# Cluster de um node só: sem tirar este label o node não entra como backend do LB.
kubectl label node "${CLUSTER}-control-plane" node.kubernetes.io/exclude-from-external-load-balancers- >/dev/null 2>&1 || true
# Roda no host, não em container: no Docker Desktop o container não alcança as
# portas publicadas do Envoy e o LB fica <pending> para sempre.
if ! { [ -f "$CPK_PID" ] && kill -0 "$(cat "$CPK_PID")" 2>/dev/null; }; then
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) os=windows; exe=cloud-provider-kind.exe ;;
    Darwin) os=darwin; exe=cloud-provider-kind ;;
    *) os=linux; exe=cloud-provider-kind ;;
  esac
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
  CPK_BIN="$BIN_DIR/$exe"
  if [ ! -x "$CPK_BIN" ]; then
    mkdir -p "$BIN_DIR"
    tarball="cloud-provider-kind_${CPK_VERSION#v}_${os}_${arch}.tar.gz"
    base="https://github.com/kubernetes-sigs/cloud-provider-kind/releases/download/${CPK_VERSION}"
    curl -fsSL -o "$BIN_DIR/$tarball" "$base/$tarball"
    expected="$(curl -fsSL "$base/cloud-provider-kind_${CPK_VERSION#v}_checksums.txt" | grep " ${tarball}\$" | cut -d' ' -f1)"
    actual="$( (sha256sum "$BIN_DIR/$tarball" 2>/dev/null || shasum -a 256 "$BIN_DIR/$tarball") | cut -d' ' -f1)"
    [ -n "$expected" ] && [ "$expected" = "$actual" ] || { echo "checksum inválido: $tarball" >&2; exit 1; }
    tar -xzf "$BIN_DIR/$tarball" -C "$BIN_DIR" "$exe"
    rm -f "$BIN_DIR/$tarball"
  fi
  nohup "$CPK_BIN" > "$BIN_DIR/cloud-provider-kind.log" 2>&1 &
  echo $! > "$CPK_PID"
fi

step "Infraestrutura compartilhada + OpenSearch"
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/
kubectl apply -f aws-local/opensearch.yaml

# shellcheck source=../ci/services.sh
. ci/services.sh

TAGS_FILE="$ROOT/aws-local/.tags"
if [ -z "${SKIP_BUILD:-}" ]; then
  : > "$TAGS_FILE"
  for entry in "${SERVICES[@]}"; do
    IFS='|' read -r name repo context _ _ <<<"$entry"
    image="${REGISTRY}/fiapgames/${name}:$(image_tag "$WORKSPACE/$repo")"
    step "Build e push ${image}"
    docker build -t "$image" "$WORKSPACE/$repo/$context"
    docker push "$image"
    echo "${name}=${image}" >> "$TAGS_FILE"
  done
elif [ ! -f "$TAGS_FILE" ]; then
  echo "SKIP_BUILD exige um build anterior (aws-local/.tags não existe)" >&2
  exit 1
fi

step "Microsserviços"
# Mesmo script de deploy que a pipeline usa no EKS.
for entry in "${SERVICES[@]}"; do
  IFS='|' read -r name repo _ _ placeholder <<<"$entry"
  image="$(grep "^${name}=" "$TAGS_FILE" | cut -d= -f2-)"
  KUBE_CONTEXT="kind-${CLUSTER}" ci/deploy.sh "$WORKSPACE/$repo/k8s" "$placeholder" "$image"
done

# A chave da Azure Function nunca é versionada: vem do .env, se existir.
FUNCTION_KEY="$(grep -s '^NOTIFICATIONS_FUNCTION_KEY=' .env | cut -d= -f2- || true)"
if [ -n "$FUNCTION_KEY" ]; then
  for secret in payments-api-secrets user-api-secret; do
    kubectl patch secret "$secret" -n "$NAMESPACE" --type merge \
      -p "{\"stringData\":{\"Notifications__FunctionKey\":\"${FUNCTION_KEY}\"}}" >/dev/null
  done
  kubectl rollout restart deployment/payments-api deployment/user-api -n "$NAMESPACE" >/dev/null
fi

step "API Gateway (Kong + Konga)"
kubectl create secret generic kong-declarative-config -n "$NAMESPACE" \
  --from-file=kong.yml.template=kong/kong.k8s.yml --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f k8s/kong/
kubectl wait --for=condition=complete job/kong-bootstrap -n "$NAMESPACE" --timeout=300s

step "Aguardando os deployments"
for deploy in $(kubectl get deployment -n "$NAMESPACE" -o name); do
  kubectl rollout status "$deploy" -n "$NAMESPACE" --timeout=600s
done

LB=""
for _ in $(seq 1 30); do
  LB="$(kubectl get svc kong-proxy -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
  [ -n "$LB" ] && break
  sleep 2
done
# Fora do Linux o IP do LB não é roteável do host; o Envoy publica a porta 80 numa porta aleatória.
LB_CONTAINER="$(docker ps -q --filter "label=io.x-k8s.cloud-provider-kind.loadbalancer.name=${CLUSTER}/${NAMESPACE}/kong-proxy")"
LB_HOST_PORT="$( [ -n "$LB_CONTAINER" ] && docker port "$LB_CONTAINER" 80 | head -1 | sed 's/.*://' || true)"
cat <<EOF

Pronto.
  Gateway (NodePort):        http://localhost:8000
  Load balancer kong-proxy:  EXTERNAL-IP ${LB:-pendente}${LB_HOST_PORT:+, no host: http://localhost:${LB_HOST_PORT}}
  Registry (ECR local):      http://${REGISTRY}/v2/_catalog
  OpenSearch:                kubectl port-forward -n ${NAMESPACE} svc/opensearch 9200:9200
EOF
