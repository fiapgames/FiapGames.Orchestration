# Microsserviços implantados no cluster, lidos por aws-local/up.sh, infra/aws.sh e ci/simulate-pipeline.sh.
# imagem | repositório | contexto do docker build | solução | imagem escrita nos manifestos do repositório
# shellcheck disable=SC2034
SERVICES=(
  "catalog-api|FiapGames.Catalog|.|FiapGames.Catalog.sln|brendhom/fiapgames-catalog-api:latest"
  "users-api|Fiap.Games.Users|User.Games.Fiap|User.Games.Fiap.slnx|user-games-fiap:latest"
  "payments-api|FiapGames.Payments|.|FiapGames.Payments.sln|lucasceifador/fiapgames-payments-api:latest"
)

# Tag = commit do repositório, com sufixo quando há mudança não commitada.
image_tag() {
  local repo="$1" sha
  sha="$(git -C "$repo" rev-parse --short HEAD)"
  if [ -n "$(git -C "$repo" status --porcelain)" ]; then
    echo "${sha}-dirty-$(date +%s)"
  else
    echo "$sha"
  fi
}
