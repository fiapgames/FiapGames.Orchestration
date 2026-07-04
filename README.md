# FiapGames.Orchestration

Repositório de orquestração do FiapGames (Tech Challenge Fase 2). Não contém código de aplicação — apenas o `docker-compose.yml` que sobe todos os microsserviços juntos, compartilhando um único RabbitMQ, e instruções de deploy no Kubernetes.

Assume que os repositórios dos microsserviços estão clonados **lado a lado** com este:

```
projeto pos parte 2/
├── FiapGames.Catalog/
├── FiapGames.Contracts/
├── FiapGames.Notifications/
├── FiapGames.Orchestration/   <- este repositório
└── FiapGames.Payments/
```

> "UsersAPI ainda não existe" quando for criado, adicionar o serviço aqui seguindo o mesmo padrão dos demais.

## Serviços

| Serviço | Porta (host) | Depende de |
|---|---|---|
| `rabbitmq` | 5672 (AMQP), 15672 (management UI) | — |
| `sqlserver-catalog` | 1433 | — |
| `postgres-payments` | 5432 | — |
| `postgres-notifications` | 5433 | — |
| `mailhog` | 1025 (SMTP), 8025 (web UI) | — |
| `catalog-api` | 8080 | rabbitmq, sqlserver-catalog |
| `payments-api` | 8081 | rabbitmq, postgres-payments |
| `notifications-api` | 8082 | rabbitmq, postgres-notifications, mailhog |

## Executando localmente

```bash
docker compose up -d --build
```

Isso builda a imagem de cada API a partir do Dockerfile do respectivo repositório irmão, sobe um único RabbitMQ compartilhado, os bancos de cada serviço, e o Mailhog (simula envio de e-mail do Notifications).

Endpoints úteis:

- Catalog: `http://localhost:8080/swagger` | `http://localhost:8080/health`
- Payments: `http://localhost:8081/health`
- Notifications: `http://localhost:8082/health`
- RabbitMQ management: `http://localhost:15672` (usuário `fiapgames-admin`, senha `FiapGames@Admin123`)
- Mailhog (e-mails simulados): `http://localhost:8025`

### Testando o fluxo de compra completo

```bash
# 1. cria um jogo
curl -X POST http://localhost:8080/games -H "Content-Type: application/json" \
  -d '{"title":"Hollow Knight","description":"Metroidvania","price":39.90,"genre":"Platformer"}'

# 2. compra o jogo (troque {gameId} pelo id retornado acima)
curl -X POST http://localhost:8080/games/{gameId}/purchase -H "Content-Type: application/json" \
  -d '{"userId":"11111111-1111-1111-1111-111111111111"}'

# 3. acompanha o pedido até virar Approved/Rejected (processado de forma assíncrona pelo Payments)
curl http://localhost:8080/orders/{orderId}

# 4. confere a biblioteca do usuário
curl http://localhost:8080/users/11111111-1111-1111-1111-111111111111/library
```

Encerrar tudo:

```bash
docker compose down -v
```

## Deploy no Kubernetes

Cada microsserviço mantém seus próprios manifestos (`Deployment`, `ConfigMap`, `Secret`, e no caso do Catalog também `Service`) em `k8s/` no respectivo repositório. Esses manifestos assumem que a infraestrutura compartilhada (RabbitMQ, Postgres, SQL Server, Mailhog) já existe no cluster com hostnames fixos:

- `rabbitmq.fiapgames.svc.cluster.local` (Payments, Notifications, Catalog)
- `postgres.fiapgames.svc.cluster.local` (um único Postgres compartilhado — Payments e Notifications usam bases diferentes nele: `fiapgames-payments` e `fiapgames-notifications`)
- `sqlserver.fiapgames.svc.cluster.local` (Catalog)
- `mailhog.fiapgames.svc.cluster.local` (Notifications)

Nenhum repositório de microsserviço traz manifesto de Deployment/Service para essa infraestrutura — por isso os manifestos de infra (`rabbitmq.yaml`, `postgres.yaml`, `sqlserver.yaml`, `mailhog.yaml`) vivem aqui, em `k8s/`.

### Passo a passo testado (cluster local com Kind)

```bash
# 1. cria o cluster local
kind create cluster --name fiapgames

# 2. sobe a infraestrutura compartilhada (namespace + rabbitmq + postgres + sqlserver + mailhog)
kubectl apply -f k8s/

# 3. builda as imagens das APIs (via docker compose, reaproveitando os Dockerfiles dos repositórios irmãos)
docker compose build

# 4. tageia as imagens com os nomes usados nos manifests de cada repositório
docker tag fiapgamesorchestration-catalog-api:latest brendhom/fiapgames-catalog-api:latest
docker tag fiapgamesorchestration-payments-api:latest lucasceifador/fiapgames-payments-api:latest
docker tag fiapgamesorchestration-notifications-api:latest lucasceifador/fiapgames-notifications-api:latest

# 5. carrega as imagens direto no cluster kind (sem precisar de um registry)
kind load docker-image brendhom/fiapgames-catalog-api:latest --name fiapgames
kind load docker-image lucasceifador/fiapgames-payments-api:latest --name fiapgames
kind load docker-image lucasceifador/fiapgames-notifications-api:latest --name fiapgames

# 6. aplica os manifestos de cada microsserviço
kubectl apply -f ../FiapGames.Catalog/k8s/
kubectl apply -f ../FiapGames.Payments/k8s/
kubectl apply -f ../FiapGames.Notifications/k8s/

# 7. como as imagens não estão publicadas num registry real, force o cluster a usar
#    a imagem carregada localmente em vez de tentar puxar do Docker Hub
kubectl patch deployment catalog-api -n fiapgames -p '{"spec":{"template":{"spec":{"containers":[{"name":"catalog-api","imagePullPolicy":"IfNotPresent"}]}}}}'
kubectl patch deployment payments-api -n fiapgames -p '{"spec":{"template":{"spec":{"containers":[{"name":"payments-api","imagePullPolicy":"IfNotPresent"}]}}}}'
kubectl patch deployment notifications-api -n fiapgames -p '{"spec":{"template":{"spec":{"containers":[{"name":"notifications-api","imagePullPolicy":"IfNotPresent"}]}}}}'

kubectl get pods -n fiapgames
```

> O passo 7 (`imagePullPolicy: IfNotPresent`) só é necessário para teste local com Kind, porque as imagens não foram publicadas de verdade no Docker Hub ainda. Depois que as imagens forem publicadas (`docker push`) e os manifestos apontarem para um registry real, isso deixa de ser necessário — o comportamento padrão (`imagePullPolicy: Always` para tag `latest`) volta a ser o correto.

**Resultado esperado** — todos os 7 pods `1/1 Running`:

```
NAME                                 READY   STATUS    RESTARTS   AGE
catalog-api-xxxxxxxxxx-xxxxx         1/1     Running   0          5m
mailhog-xxxxxxxxxx-xxxxx             1/1     Running   0          14m
notifications-api-xxxxxxxxxx-xxxxx   1/1     Running   0          5m
payments-api-xxxxxxxxxx-xxxxx        1/1     Running   0          5m
postgres-xxxxxxxxxx-xxxxx            1/1     Running   0          7m
rabbitmq-xxxxxxxxxx-xxxxx            1/1     Running   0          7m
sqlserver-xxxxxxxxxx-xxxxx           1/1     Running   0          14m
```

Testando o fluxo de compra através do Service do Catalog (Payments e Notifications não expõem Service HTTP — eles só reagem a eventos do RabbitMQ):

```bash
kubectl port-forward -n fiapgames svc/catalog-api 8090:80

# em outro terminal
curl -X POST http://localhost:8090/games -H "Content-Type: application/json" \
  -d '{"title":"Terraria","description":"Sandbox","price":19.90,"genre":"Sandbox"}'

curl -X POST http://localhost:8090/games/{gameId}/purchase -H "Content-Type: application/json" \
  -d '{"userId":"44444444-4444-4444-4444-444444444444"}'

curl http://localhost:8090/orders/{orderId}
curl http://localhost:8090/users/44444444-4444-4444-4444-444444444444/library
```

Isso foi validado de ponta a ponta: `payments-api` consome `OrderPlacedEvent` e processa o pagamento sozinho, `catalog-api` consome `PaymentProcessedEvent` e atualiza o pedido/biblioteca, `notifications-api` consome o mesmo evento e loga o e-mail — tudo dentro do cluster, sem simulação manual.

Encerrar o cluster:

```bash
kind delete cluster --name fiapgames
```
