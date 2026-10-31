#!/usr/bin/env bash
# Liga e desliga a infraestrutura da AWS via CloudFormation.
#
#   ./infra/aws.sh lint          # cfn-lint nos templates, sem tocar na AWS
#   ./infra/aws.sh plan          # valida na AWS e mostra o change set das stacks que já existem
#   ./infra/aws.sh up            # liga: stacks + infra compartilhada + apps (~35 min do zero)
#   ./infra/aws.sh down          # desliga: apaga tudo que cobra por hora
#   ./infra/aws.sh keep-alive    # conta como uso agora (adia o desligamento automático)
#   ./infra/aws.sh outputs       # endpoints, registry e roles do GitHub
#   ./infra/aws.sh destroy       # down + apaga também a base permanente (ECR, roles, budget)
#
# BUDGET_EMAIL=voce@exemplo.com  inclui o alerta de custo
# IDLE_MINUTES=10                minutos sem uso até o desligamento automático (stack auto-off)
# EKS_ADMIN_ARN=arn:...          pessoa com acesso de admin ao cluster (padrão: o usuário IAM atual)
set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true  # bash < 4.4 (macOS) não tem

PREFIX=fiapgames
CLUSTER=fiapgames
NAMESPACE=fiapgames
CONTEXT="aws-${CLUSTER}"
REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
REGION="${REGION:-us-east-2}"
export AWS_REGION="$REGION" AWS_PAGER=""

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$(cd "$ROOT/.." && pwd)"
TEMPLATES="infra/cloudformation"
cd "$ROOT"
# shellcheck source=../ci/services.sh
. ci/services.sh

step() { printf '\n==> %s\n' "$*"; }

stack_exists() {
  aws cloudformation describe-stacks --stack-name "$1" >/dev/null 2>&1
}

stack_output() {
  aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}

# Quem roda localmente com um usuário IAM vira admin do cluster; no GitHub vale EKS_ADMIN_ARN.
eks_admin_arn() {
  if [ -n "${EKS_ADMIN_ARN:-}" ]; then echo "$EKS_ADMIN_ARN"; return; fi
  local arn
  arn="$(aws sts get-caller-identity --query Arn --output text)"
  case "$arn" in *:user/*) echo "$arn" ;; *) echo "" ;; esac
}

# stack | template | parâmetros (separados por espaço)
# Permanentes: não cobram por hora e precisam sobreviver ao "down".
permanent_stacks() {
  echo "${PREFIX}-base|00-base.yaml|"
  echo "${PREFIX}-ecr|02-ecr.yaml|"
  echo "${PREFIX}-auto-off|07-auto-off.yaml|ClusterName=${CLUSTER} Namespace=${NAMESPACE}${IDLE_MINUTES:+ IdleMinutes=${IDLE_MINUTES}}"
  [ -n "${BUDGET_EMAIL:-}" ] && echo "${PREFIX}-budget|06-budget.yaml|AlertEmail=${BUDGET_EMAIL}"
  return 0
}
# Do ambiente: tudo que cobra por hora, na ordem de criação.
env_stacks() {
  echo "${PREFIX}-network|01-network.yaml|ClusterName=${CLUSTER}"
  # Sem admin informado, o "deploy" mantém o valor que a stack já tinha.
  local admin
  admin="$(eks_admin_arn)"
  echo "${PREFIX}-eks|03-eks.yaml|NetworkStackName=${PREFIX}-network BaseStackName=${PREFIX}-base ClusterName=${CLUSTER}${admin:+ ExtraAdminArn=${admin}}"
  echo "${PREFIX}-opensearch|04-opensearch.yaml|NetworkStackName=${PREFIX}-network EksStackName=${PREFIX}-eks"
  echo "${PREFIX}-github|05-github-actions.yaml|EcrStackName=${PREFIX}-ecr EksStackName=${PREFIX}-eks Namespace=${NAMESPACE}"
}

# No Git Bash, nomes do SSM como /fiapgames/... não podem virar caminho do Windows.
ssm() { MSYS_NO_PATHCONV=1 aws ssm "$@"; }

# Marca uso agora, para o desligamento automático não agir no meio de uma operação.
touch_activity() {
  ssm put-parameter --name "/${PREFIX}/auto-off/last-activity" --value "$(date +%s)"     --type String --overwrite >/dev/null
}

# O CloudFormation cria a função com um código provisório; o de verdade sobe daqui.
upload_auto_off() {
  # Caminho relativo: no Windows o python e o aws.exe não enxergam o /tmp do Git Bash.
  local zip=infra/lambda/.build/auto_off.zip py
  mkdir -p "$(dirname "$zip")"
  for py in python3 python; do "$py" -c "import zipfile" 2>/dev/null && break; done
  # Entra como index.py, o mesmo módulo do código provisório do template.
  "$py" -c "import sys, zipfile; z = zipfile.ZipFile(sys.argv[1], 'w'); z.write(sys.argv[2], 'index.py'); z.close()"     "$zip" infra/lambda/auto_off.py
  aws lambda update-function-code --function-name "${PREFIX}-auto-off" --zip-file "fileb://${zip}" >/dev/null
  aws lambda wait function-updated-v2 --function-name "${PREFIX}-auto-off"
}

deploy_stack() {
  local stack="$1" template="$2" params="$3"
  step "Stack ${stack} (${template})"
  ssm get-parameter --name "/${PREFIX}/auto-off/last-activity" >/dev/null 2>&1 && touch_activity
  # shellcheck disable=SC2086
  aws cloudformation deploy --stack-name "$stack" --template-file "$TEMPLATES/$template" \
    --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset \
    ${params:+--parameter-overrides $params} --tags project=fiapgames
  if [ "$stack" = "${PREFIX}-auto-off" ]; then
    upload_auto_off
  fi
}

delete_stack() {
  stack_exists "$1" || return 0
  step "Apagando $1"
  aws cloudformation delete-stack --stack-name "$1"
  aws cloudformation wait stack-delete-complete --stack-name "$1"
}

kube() { kubectl --context "$CONTEXT" "$@"; }

cmd_lint() {
  if command -v cfn-lint >/dev/null; then
    cfn-lint --regions "$REGION" -- "$TEMPLATES"/*.yaml
  else
    # Sem cfn-lint instalado, roda num container descartável.
    MSYS_NO_PATHCONV=1 docker run --rm -v "$ROOT/infra:/infra:ro" python:3.13-slim \
      sh -c "pip install -q --root-user-action=ignore cfn-lint && cfn-lint --regions $REGION -- /infra/cloudformation/*.yaml"
  fi
  echo "cfn-lint: ok"
}

cmd_plan() {
  while IFS='|' read -r stack template params; do
    step "$stack"
    aws cloudformation validate-template --template-body "file://$TEMPLATES/$template" >/dev/null
    if ! stack_exists "$stack"; then
      echo "ainda não existe: será criada no 'up'"
      continue
    fi
    local cs
    cs="plan-$(date +%s)"
    local args=(--stack-name "$stack" --change-set-name "$cs" --capabilities CAPABILITY_NAMED_IAM
      --template-body "file://$TEMPLATES/$template")
    if [ -n "$params" ]; then
      args+=(--parameters)
      for p in $params; do args+=("ParameterKey=${p%%=*},ParameterValue=${p#*=}"); done
    fi
    aws cloudformation create-change-set "${args[@]}" >/dev/null
    aws cloudformation wait change-set-create-complete --stack-name "$stack" --change-set-name "$cs" 2>/dev/null || true
    aws cloudformation describe-change-set --stack-name "$stack" --change-set-name "$cs" \
      --query '[StatusReason, Changes[].ResourceChange.[Action,LogicalResourceId,ResourceType,Replacement]]' --output text
    aws cloudformation delete-change-set --stack-name "$stack" --change-set-name "$cs"
  done < <(permanent_stacks; env_stacks)
}

# Push por um docker CLI em container: no Windows o cofre de credenciais recusa o
# token do ECR, grande demais para ele. Funciona igual no Linux e no Mac.
ecr_push() {
  ECR_TOKEN="$(aws ecr get-login-password)" MSYS_NO_PATHCONV=1 docker run --rm -e ECR_TOKEN \
    -v /var/run/docker.sock:/var/run/docker.sock docker:27.5.1-cli \
    sh -c 'echo "$ECR_TOKEN" | docker login -u AWS --password-stdin "${0%%/*}" >/dev/null && docker push "$0"' "$1"
}

# Última imagem publicada no ECR; sem nenhuma, builda a partir do repositório ao lado.
service_image() {
  local name="$1" repo="$2" context="$3" registry="$4" tag
  tag="$(aws ecr describe-images --repository-name "fiapgames/${name}" \
    --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' --output text 2>/dev/null || true)"
  if [ -z "$tag" ] || [ "$tag" = "None" ]; then
    tag="$(image_tag "$WORKSPACE/$repo")"
    step "ECR vazio para ${name}: build de ${repo}" >&2
    docker build -t "${registry}/fiapgames/${name}:${tag}" "$WORKSPACE/$repo/$context" >&2
    ecr_push "${registry}/fiapgames/${name}:${tag}" >&2
  fi
  echo "${registry}/fiapgames/${name}:${tag}"
}

cmd_bootstrap() {
  for entry in "${SERVICES[@]}"; do
    IFS='|' read -r _ repo _ _ _ <<<"$entry"
    [ -d "$WORKSPACE/$repo/k8s" ] || { echo "faltando $WORKSPACE/$repo: clone os repositórios lado a lado" >&2; exit 1; }
  done
  aws eks update-kubeconfig --name "$CLUSTER" --alias "$CONTEXT" >/dev/null

  step "Infraestrutura compartilhada"
  kube apply -f k8s/namespace.yaml
  # Conta o tempo do bootstrap como uso, para o desligamento automático não agir no meio dele.
  touch_activity

  step "Secrets"
  # No GitHub vêm dos Secrets do repositório; o que faltar é gerado e fica só no cluster.
  # Localmente, só as chaves externas saem do .env: as senhas da AWS nunca são as do Kind.
  local var
  for var in NEW_RELIC_LICENSE_KEY; do
    [ -n "${!var:-}" ] || export "$var=$(grep -s "^${var}=" .env | tr -d '\r' | cut -d= -f2- || true)"
  done
  KUBE_CONTEXT="$CONTEXT" ci/secrets.sh apply
  kube apply -f k8s/

  step "API Gateway (Kong + Konga)"
  kube create secret generic kong-declarative-config -n "$NAMESPACE" \
    --from-file=kong.yml.template=kong/kong.k8s.yml --dry-run=client -o yaml | kube apply -f -
  kube apply -f k8s/kong/
  kube wait --for=condition=complete job/kong-bootstrap -n "$NAMESPACE" --timeout=600s

  step "Microsserviços (última imagem do ECR)"
  local registry
  registry="$(stack_output "${PREFIX}-ecr" RegistryUri)"
  for entry in "${SERVICES[@]}"; do
    IFS='|' read -r name repo context _ placeholder <<<"$entry"
    KUBE_CONTEXT="$CONTEXT" ci/deploy.sh "$WORKSPACE/$repo/k8s" "$placeholder" \
      "$(service_image "$name" "$repo" "$context" "$registry")"
  done

  touch_activity
}

set_auto_off_state() {
  ssm put-parameter --name "/${PREFIX}/auto-off/state" --value "$1" --type String --overwrite >/dev/null
  touch_activity
}

cmd_up() {
  # "starting" segura o desligamento automático até o fim e vence um desligamento em curso.
  set_auto_off_state starting
  # O domínio do OpenSearch dentro da VPC exige esta role; ela só pode existir uma vez por conta.
  aws iam create-service-linked-role --aws-service-name opensearchservice.amazonaws.com >/dev/null 2>&1 || true
  while IFS='|' read -r stack template params; do
    deploy_stack "$stack" "$template" "$params"
  done < <(permanent_stacks; env_stacks)

  cmd_bootstrap
  set_auto_off_state on

  local lb
  lb="$(kube get svc kong-proxy -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  cmd_outputs
  echo
  echo "Gateway: http://${lb:-<load balancer ainda sendo criado: kubectl --context ${CONTEXT} get svc kong-proxy -n ${NAMESPACE}>}"
}

# Load balancers criados pelo Kubernetes não pertencem a nenhuma stack e travam a remoção da VPC.
delete_k8s_load_balancers() {
  aws eks describe-cluster --name "$CLUSTER" >/dev/null 2>&1 || return 0
  aws eks update-kubeconfig --name "$CLUSTER" --alias "$CONTEXT" >/dev/null
  local services
  services="$(kube get svc -A \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')"
  [ -z "$services" ] && return 0
  for svc in $services; do
    kube delete svc -n "${svc%%/*}" "${svc#*/}" --wait=true
  done
  local vpc
  vpc="$(stack_output "${PREFIX}-network" VpcId)"
  for _ in $(seq 1 30); do
    local classic network
    classic="$(aws elb describe-load-balancers --query "length(LoadBalancerDescriptions[?VPCId=='${vpc}'])" --output text)"
    network="$(aws elbv2 describe-load-balancers --query "length(LoadBalancers[?VpcId=='${vpc}'])" --output text)"
    [ $((classic + network)) -eq 0 ] && return 0
    sleep 10
  done
  echo "load balancers ainda presentes na VPC ${vpc}; a remoção da rede pode falhar" >&2
}

cmd_down() {
  step "Load balancers criados pelo Kubernetes"
  delete_k8s_load_balancers
  local stacks=()
  while IFS='|' read -r stack _ _; do stacks=("$stack" "${stacks[@]}"); done < <(env_stacks)
  for stack in "${stacks[@]}"; do delete_stack "$stack"; done
  kubectl config delete-context "$CONTEXT" >/dev/null 2>&1 || true
  echo "Ambiente desligado. Continuam de pé (sem custo por hora): base, ECR e budget."
}

cmd_destroy() {
  cmd_down
  delete_stack "${PREFIX}-budget"
  delete_stack "${PREFIX}-ecr"
  delete_stack "${PREFIX}-base"
}

cmd_keep_alive() {
  touch_activity
  echo "uso registrado: o desligamento automático recomeça a contar agora"
}

cmd_outputs() {
  step "Saídas"
  for stack in "${PREFIX}-base" "${PREFIX}-ecr" "${PREFIX}-eks" "${PREFIX}-opensearch" "${PREFIX}-github"; do
    stack_exists "$stack" || continue
    aws cloudformation describe-stacks --stack-name "$stack" \
      --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output text
  done
}

case "${1:-}" in
  lint) cmd_lint ;;
  plan) cmd_plan ;;
  up) cmd_up ;;
  bootstrap) cmd_bootstrap ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  keep-alive) cmd_keep_alive ;;
  outputs) cmd_outputs ;;
  *) sed -n '2,15p' "$0" | grep -v '^$'; exit 1 ;;
esac
