#!/usr/bin/env bash
# Cria os Secrets do Kubernetes a partir de variáveis de ambiente (GitHub Secrets
# no workflow, .env localmente). Nenhuma senha fica versionada: o que não vier do
# ambiente reaproveita o valor que já está no cluster ou é gerado na hora.
#
#   ci/secrets.sh apply            # Secrets no namespace (KUBE_CONTEXT escolhe o cluster)
#   ci/secrets.sh dotenv .env      # completa o .env com senhas aleatórias (compose e Kind)
set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true  # bash < 4.4 (macOS) não tem

NAMESPACE="${NAMESPACE:-fiapgames}"
STORE=infra-credentials
kctl() { kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }

# variável de ambiente | chave no Secret infra-credentials
GENERATED=(
  "SQLSERVER_CATALOG_PASSWORD|sqlserver-catalog-password"
  "SQLSERVER_USERS_PASSWORD|sqlserver-users-password"
  "POSTGRES_PASSWORD|postgres-password"
  "MONGO_PASSWORD|mongo-password"
  "RABBITMQ_PASSWORD|rabbitmq-password"
  "KONG_DB_PASSWORD|kong-db-password"
  "KONGA_ADMIN_PASSWORD|konga-admin-password"
  "KONGA_TOKEN_SECRET|konga-token-secret"
  "JWT_SECRET_KEY|jwt-secret-key"
)

# Só letras e números: entram em connection strings e URIs sem escape. O sufixo
# garante maiúscula, minúscula e dígito, que a política do SQL Server exige.
random_secret() {
  local s
  s="$(head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
  echo "${s:0:40}Aa1"
}

cluster_value() {
  kctl get secret "$STORE" -n "$NAMESPACE" -o go-template="{{index .data \"$1\" | base64decode}}" 2>/dev/null || true
}

secret_from_literals() {
  local name="$1"; shift
  local args=()
  for kv in "$@"; do args+=(--from-literal="$kv"); done
  kctl create secret generic "$name" -n "$NAMESPACE" "${args[@]}" --dry-run=client -o yaml | kctl apply -f - >/dev/null
  echo "secret/${name} pronto"
}

cmd_apply() {
  local literals=() var key value
  for entry in "${GENERATED[@]}"; do
    IFS='|' read -r var key <<<"$entry"
    value="${!var:-}"
    [ -n "$value" ] || value="$(cluster_value "$key")"
    [ -n "$value" ] || value="$(random_secret)"
    printf -v "$var" '%s' "$value"
    literals+=("${key}=${value}")
  done
  secret_from_literals "$STORE" "${literals[@]}"

  local rabbit_user=fiapgames-admin
  secret_from_literals catalog-api-secrets \
    "ConnectionStrings__SqlServer=Server=sqlserver.${NAMESPACE}.svc.cluster.local,1433;Database=fiapgames-catalog;User Id=sa;Password=${SQLSERVER_CATALOG_PASSWORD};TrustServerCertificate=True" \
    "ConnectionStrings__Mongo=mongodb://fiapgames-admin:${MONGO_PASSWORD}@mongodb.${NAMESPACE}.svc.cluster.local:27017" \
    "RabbitMq__UserName=${rabbit_user}" "RabbitMq__Password=${RABBITMQ_PASSWORD}" \
    "Jwt__SecretKey=${JWT_SECRET_KEY}"
  secret_from_literals user-api-secret \
    "ConnectionStrings__SqlServer=Server=sqlserver-users,1433;Database=UserGamesFiap;User Id=sa;Password=${SQLSERVER_USERS_PASSWORD};TrustServerCertificate=True;Encrypt=False" \
    "RabbitMq__UserName=${rabbit_user}" "RabbitMq__Password=${RABBITMQ_PASSWORD}" \
    "Jwt__SecretKey=${JWT_SECRET_KEY}"
  secret_from_literals payments-api-secrets \
    "ConnectionStrings__Postgres=Host=postgres.${NAMESPACE}.svc.cluster.local;Port=5432;Database=fiapgames-payments;Username=fiapgames-admin;Password=${POSTGRES_PASSWORD}" \
    "RabbitMq__UserName=${rabbit_user}" "RabbitMq__Password=${RABBITMQ_PASSWORD}"

  # Opcional: sem ele o Kong e os agentes seguem com a observabilidade desligada.
  if [ -n "${NEW_RELIC_LICENSE_KEY:-}" ]; then
    secret_from_literals newrelic "license-key=${NEW_RELIC_LICENSE_KEY}"
  fi
}

cmd_dotenv() {
  local file="${1:?informe o arquivo .env}" var current
  touch "$file"
  for entry in "${GENERATED[@]}"; do
    var="${entry%%|*}"
    current="$(grep -E "^${var}=" "$file" | tail -1 | cut -d= -f2- || true)"
    [ -n "$current" ] && continue
    sed -i "/^${var}=\$/d" "$file"
    echo "${var}=$(random_secret)" >> "$file"
    echo "${var} gerada em ${file}"
  done
}

case "${1:-}" in
  apply) cmd_apply ;;
  dotenv) cmd_dotenv "${2:-}" ;;
  *) sed -n '2,7p' "$0"; exit 1 ;;
esac
