# FiapGames.Orchestration

Repositório de orquestração do FiapGames (Tech Challenge Fase 2). Não contém código de aplicação — apenas o `docker-compose.yml` que sobe os microsserviços juntos, compartilhando um único RabbitMQ, e instruções de deploy no Kubernetes.

> **O Notifications não faz mais parte desta stack.** Ele foi migrado para **Azure Functions serverless** e roda na nuvem, em `https://fiap-games-notification-hdaza0g6fudjc3ak.westus3-01.azurewebsites.net`. Users e Payments passaram a notificá-lo por HTTP, e não mais via RabbitMQ.

Assume que os repositórios dos microsserviços estão clonados **lado a lado** com este:

```
projeto pos parte 2/
├── Fiap.Games.Users/           <- UsersAPI (pasta do projeto: User.Games.Fiap/)
├── FiapGames.Catalog/
├── FiapGames.Contracts/
├── FiapGames.Notifications/    <- agora serverless (Azure Functions), não sobe local
├── FiapGames.Orchestration/    <- este repositório
└── FiapGames.Payments/
```

## Serviços

| Serviço | Porta (host) | Depende de |
|---|---|---|
| `rabbitmq` | 5672 (AMQP), 15672 (management UI) | — |
| `sqlserver-catalog` | 1433 | — |
| `sqlserver-users` | 1434 | — |
| `postgres-payments` | 5432 | — |
| `catalog-api` | 8080 | rabbitmq, sqlserver-catalog |
| `payments-api` | 8081 | rabbitmq, postgres-payments |
| `users-api` | 8083 | rabbitmq, sqlserver-users |

O Notifications não aparece na tabela porque é serverless — não há container, banco nem porta local para ele.

## Executando localmente

Antes de subir, crie um arquivo `.env` neste diretório com a chave da Azure Function de notificações:

```bash
echo 'NOTIFICATIONS_FUNCTION_KEY=<chave da function>' > .env
```

A chave sai de:

```bash
az functionapp keys list -g fiap-games -n fiap-games-notification --query "functionKeys.default" -o tsv
```

O `.env` não deve ser versionado. Sem ele, Users e Payments sobem normalmente, mas as chamadas de notificação recebem `401`.

```bash
docker compose up -d --build
```

Isso builda a imagem de cada API a partir do Dockerfile do respectivo repositório irmão, sobe um único RabbitMQ compartilhado e o banco de cada serviço.

Endpoints úteis:

- Catalog: `http://localhost:8080/swagger` | `http://localhost:8080/health`
- Payments: `http://localhost:8081/health`
- Users: `http://localhost:8083/swagger` | `http://localhost:8083/health`
- RabbitMQ management: `http://localhost:15672` (usuário `fiapgames-admin`, senha `FiapGames@Admin123`)
- Notifications (Azure): `https://fiap-games-notification-hdaza0g6fudjc3ak.westus3-01.azurewebsites.net/api/health`

### Testando os dois fluxos completos (cadastro + compra)

Validado de ponta a ponta com os 4 serviços reais rodando juntos, sem nenhuma simulação manual de evento.

```bash
# 1. cadastra um usuário no UsersAPI -> chama a Function de notificações por HTTP
curl -X POST http://localhost:8083/api/users -H "Content-Type: application/json" \
  -d '{"nome":"Maria Silva","email":"maria@example.com","password":"SenhaForte@123"}'
# a notificação de boas-vindas aparece no Application Insights (ver "Conferindo as notificações")

# 2. cria um jogo no Catalog
curl -X POST http://localhost:8080/games -H "Content-Type: application/json" \
  -d '{"title":"Elden Ring","description":"Souls-like","price":49.90,"genre":"RPG"}'

# 3. compra o jogo (troque {gameId} e {userId} pelos ids retornados acima)
#    -> Catalog publica OrderPlacedEvent -> Payments processa -> publica PaymentProcessedEvent
#    -> Catalog atualiza o pedido/biblioteca, e o Payments chama a Function de notificações
curl -X POST http://localhost:8080/games/{gameId}/purchase -H "Content-Type: application/json" \
  -d '{"userId":"{userId}"}'

# 4. acompanha o pedido até virar Approved/Rejected
curl http://localhost:8080/orders/{orderId}

# 5. confere a biblioteca do usuário — o Catalog busca nome/e-mail reais no UsersAPI
#    via request/response no RabbitMQ (UserLookupRequested/Responded) antes de responder
curl http://localhost:8080/library/{userId}
```

### Conferindo as notificações

Como o Notifications virou serverless, as notificações não vão mais para o Mailhog — elas são registradas no Application Insights do Azure.

```bash
az monitor app-insights query --app fiap-games-notification -g fiap-games \
  --analytics-query "traces | where timestamp > ago(30m) | where message contains 'NOTIFICA' | project timestamp, message | order by timestamp desc"
```

Há um atraso de 1 a 3 minutos na ingestão. Para acompanhar em tempo real:

```bash
az webapp log tail -g fiap-games -n fiap-games-notification
```

Encerrar tudo:

```bash
docker compose down -v
```

## Deploy no Kubernetes

> **O Notifications não é mais implantado no cluster** — virou Azure Functions serverless. Os manifestos abaixo cobrem Catalog, Payments e Users.

> **Status atual: os microsserviços foram testados no cluster Kind.** O `Fiap.Games.Users` originalmente trazia sua própria pasta `k8s/` isolada (namespace `games-fiap`, RabbitMQ e SQL Server próprios) — foi reconciliada para usar o namespace e a infraestrutura compartilhados (`fiapgames`), do mesmo jeito que os outros três. Os manifestos de infra e RabbitMQ próprios do Users foram removidos (`00-namespace.yaml`, `rabbitmq.yaml`, `sqlserver.yaml`, `kustomization.yaml`); um novo `sqlserver-users.yaml` (SQL Server dedicado do Users, já que cada serviço tem seu próprio banco) foi adicionado aqui, em `k8s/`.

Cada microsserviço mantém seus próprios manifestos (`Deployment`, `ConfigMap`/`Secret`, e no caso do Catalog e do Users também `Service`) em `k8s/` no respectivo repositório. Esses manifestos assumem que a infraestrutura compartilhada (RabbitMQ, Postgres, SQL Server) já existe no cluster com hostnames fixos:

- `rabbitmq.fiapgames.svc.cluster.local` (Payments, Catalog, Users)
- `postgres.fiapgames.svc.cluster.local` (Payments — base `fiapgames-payments`)
- `sqlserver.fiapgames.svc.cluster.local` (Catalog)
- `sqlserver-users.fiapgames.svc.cluster.local` (Users — banco próprio, separado do SQL Server do Catalog)

Os pods de Users e Payments precisam alcançar a Azure Function pela internet. A URL vem do ConfigMap de cada serviço (`Notifications__BaseUrl`) e a chave, do Secret (`Notifications__FunctionKey`).

Nenhum repositório de microsserviço traz manifesto de Deployment/Service para essa infraestrutura — por isso os manifestos de infra (`rabbitmq.yaml`, `postgres.yaml`, `sqlserver.yaml`, `sqlserver-users.yaml`) vivem aqui, em `k8s/`. O Users também tem um `migration-job.yaml` (`Job` do Kubernetes que roda `dotnet ... --migrate` uma vez antes do Deployment subir) — os outros três serviços aplicam as migrations automaticamente no startup do próprio processo, o Users prefere um Job separado (evita corrida entre múltiplas réplicas migrando ao mesmo tempo).

### Passo a passo testado (cluster local com Kind)

```bash
# 1. cria o cluster local
kind create cluster --name fiapgames

# 2. sobe a infraestrutura compartilhada (namespace + rabbitmq + postgres + sqlserver)
kubectl apply -f k8s/

# 3. builda as imagens das APIs (via docker compose, reaproveitando os Dockerfiles dos repositórios irmãos)
docker compose build

# 4. tageia as imagens com os nomes usados nos manifests de cada repositório
docker tag fiapgamesorchestration-catalog-api:latest brendhom/fiapgames-catalog-api:latest
docker tag fiapgamesorchestration-payments-api:latest lucasceifador/fiapgames-payments-api:latest
docker tag fiapgamesorchestration-users-api:latest user-games-fiap:latest

# 5. carrega as imagens direto no cluster kind (sem precisar de um registry)
kind load docker-image brendhom/fiapgames-catalog-api:latest --name fiapgames
kind load docker-image lucasceifador/fiapgames-payments-api:latest --name fiapgames
kind load docker-image user-games-fiap:latest --name fiapgames

# 6. aplica os manifestos de cada microsserviço
kubectl apply -f ../FiapGames.Catalog/k8s/
kubectl apply -f ../FiapGames.Payments/k8s/
kubectl apply -f ../Fiap.Games.Users/k8s/

# 7. como as imagens não estão publicadas num registry real, force o cluster a usar
#    a imagem carregada localmente em vez de tentar puxar do Docker Hub
#    (o user-api.yaml e o migration-job.yaml do Users já vêm com imagePullPolicy: IfNotPresent, não precisam de patch)
#    os patches ficam em arquivo (k8s/patches/) em vez de JSON inline porque aspas duplas
#    dentro de aspas simples se perdem ao passar para o kubectl.exe no PowerShell
kubectl patch deployment catalog-api -n fiapgames --patch-file k8s/patches/catalog-api-image-pull-policy.json
kubectl patch deployment payments-api -n fiapgames --patch-file k8s/patches/payments-api-image-pull-policy.json

kubectl get pods -n fiapgames
```

> O passo 7 (`imagePullPolicy: IfNotPresent`) só é necessário para teste local com Kind, porque as imagens não foram publicadas de verdade no Docker Hub ainda. Depois que as imagens forem publicadas (`docker push`) e os manifestos apontarem para um registry real, isso deixa de ser necessário — o comportamento padrão (`imagePullPolicy: Always` para tag `latest`) volta a ser o correto.

**Resultado esperado** — todos os 7 pods `1/1 Running` + o Job de migration do Users `Completed`:

```
NAME                                 READY   STATUS      RESTARTS   AGE
catalog-api-xxxxxxxxxx-xxxxx         1/1     Running     0          5m
payments-api-xxxxxxxxxx-xxxxx        1/1     Running     0          5m
postgres-xxxxxxxxxx-xxxxx            1/1     Running     0          10m
rabbitmq-xxxxxxxxxx-xxxxx            1/1     Running     0          10m
sqlserver-xxxxxxxxxx-xxxxx           1/1     Running     0          10m
sqlserver-users-xxxxxxxxxx-xxxxx     1/1     Running     0          10m
user-api-xxxxxxxxxx-xxxxx            1/1     Running     0          5m
user-api-migrate-xxxxx               0/1     Completed   0          5m
```

### Acompanhando os logs em tempo real

`kubectl logs -f` funciona pra um pod só. Pra ver todos os pods do namespace juntos (com cor por pod), use o [`stern`](https://github.com/stern/stern):

```bash
stern -n fiapgames ".*"
```

Instalação (escolha conforme seu SO):

```bash
# Windows (winget)
winget install stern.stern

# macOS (Homebrew)
brew install stern

# Linux/macOS (Go, requer Go instalado)
go install github.com/stern/stern@latest
```

Ou baixe o binário direto em [github.com/stern/stern/releases](https://github.com/stern/stern/releases). No Windows, depois de instalar via winget pode ser necessário abrir um **novo** terminal (o PATH só é lido quando o processo inicia).

Filtrar por serviço específico (regex contra o nome do pod) ou por texto no log:

```bash
stern -n fiapgames catalog-api
stern -n fiapgames ".*" --include "error|Error|Exception"
```

Testando os dois fluxos completos através dos Services do Catalog e do Users (o Payments não expõe Service HTTP — ele só reage a eventos do RabbitMQ):

```bash
kubectl port-forward -n fiapgames svc/catalog-api 8090:80 &
kubectl port-forward -n fiapgames svc/user-api 8091:80 &

# cadastro -> notificação de boas-vindas na Azure Function
curl -X POST http://localhost:8091/api/users -H "Content-Type: application/json" \
  -d '{"nome":"Joao K8s","email":"joao.k8s@example.com","password":"SenhaForte@123"}'

# compra
curl -X POST http://localhost:8090/games -H "Content-Type: application/json" \
  -d '{"title":"Dark Souls III","description":"Souls-like","price":39.90,"genre":"RPG"}'

curl -X POST http://localhost:8090/games/{gameId}/purchase -H "Content-Type: application/json" \
  -d '{"userId":"{userId}"}'

curl http://localhost:8090/orders/{orderId}

# biblioteca — Catalog busca nome/e-mail reais no Users via RabbitMQ dentro do cluster
curl http://localhost:8090/library/{userId}
```

Validado de ponta a ponta dentro de um cluster Kind real, **antes da migração do Notifications para serverless**: o cadastro publicou `UserCreatedEvent` e o e-mail de boas-vindas chegou no Notifications; a compra foi `Approved` pelo Payments e a confirmação também chegou por e-mail; e `GET /library/{userId}` retornou nome/e-mail reais do usuário (via `UserLookupRequested`/`Responded` no RabbitMQ) junto com o jogo comprado.

> Após a migração, o trecho de notificação desse fluxo passou a ser uma chamada HTTP à Azure Function, conferível no Application Insights. **Esse novo caminho ainda não foi revalidado dentro do cluster Kind** — só o `docker compose` foi ajustado e verificado.

Encerrar o cluster:

```bash
kind delete cluster --name fiapgames
```
