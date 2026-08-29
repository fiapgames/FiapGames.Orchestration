# Observabilidade com New Relic

Item 3 do Tech Challenge, **Opção B (plataforma de APM gerenciada)**. Cobre os três
pilares que o enunciado exige — métricas, logs e traces — no gateway **e** nos quatro
microsserviços.

> **Estado atual: desligado por padrão, mas os plugins já ficam ATIVOS no arquivo.**
> Diferente da primeira versão deste guia, `http-log` e `opentelemetry` não estão mais
> comentados — eles ficam sempre presentes em `kong/kong.*.yml`, e um passo de
> bootstrap troca o placeholder `<NEW_RELIC_LICENSE_KEY>` pela chave real (ou por uma
> string vazia, se não houver chave configurada). Sem chave, a New Relic recusa os
> envios com 401/403 — visível só no log do Kong, sem afetar o tráfego normal. Ver
> [Como a chave chega lá sem tocar o arquivo](#como-a-chave-chega-lá-sem-tocar-o-arquivo).

---

## "Dá pra usar New Relic no lugar do Prometheus?"

**Não é substituição — a New Relic *consome* Prometheus.**

O plugin `prometheus` já ativo em `kong.*.yml` é a **fonte** das métricas (379 séries em
`:8100/metrics`); a New Relic é um dos **destinos** possíveis. O agente Prometheus dela
faz scrape desse endpoint e encaminha para
`https://metric-api.newrelic.com/prometheus/v1/write`.

Ou seja: manter o plugin não amarra o projeto ao Grafana. Deixe ligado — é exatamente o
que a New Relic vai ler.

---

## Como os três pilares chegam lá

| Pilar | Gateway (Kong 3.9 OSS) | Microsserviços (.NET 10) |
|---|---|---|
| **Métricas** | plugin `prometheus` → scrape/remote_write | agente APM (automático) |
| **Logs** | plugin `http-log` → Log API | agente, *logs-in-context* |
| **Traces** | plugin `opentelemetry` → OTLP `/v1/traces` | agente, distributed tracing (W3C) |

### Por que três mecanismos e não só OTLP

Seria elegante mandar tudo por OTLP com um plugin só. **Não dá nesta versão.** Exportar
logs e métricas pelo plugin `opentelemetry` só existe a partir da versão **3.13.0.0** do
plugin (dez/2025) — numeração de quatro segmentos, que é Kong **Enterprise**. O Kong OSS
para em **3.9.3** no Docker Hub. Aqui o `opentelemetry` faz **apenas traces**.

### Por que não a receita oficial da New Relic

A [documentação deles para Kong](https://docs.newrelic.com/docs/logs/forward-logs/kong-gateway/)
manda usar o plugin `file-log` apontando para `/dev/stdout` e deixar a **integração
Kubernetes da New Relic** (Fluent Bit) coletar o stdout do container. Três problemas no
nosso caso: o exemplo pressupõe o **Ingress Controller com CRDs** (`KongClusterPlugin`),
que não usamos; a integração se instala por **Helm**, que não está instalado; e nada
disso funciona no docker-compose.

O `http-log` postando direto na Log API resolve nos dois ambientes, sem Fluent Bit, sem
Helm e sem CRDs.

---

## Endpoints e credenciais

| O que | US | EU |
|---|---|---|
| Log API | `https://log-api.newrelic.com/log/v1` | `https://log-api.eu.newrelic.com/log/v1` |
| OTLP | `https://otlp.nr-data.net:4318` | `https://otlp.eu01.nr-data.net:4318` |
| Prometheus remote_write | `https://metric-api.newrelic.com/prometheus/v1/write` | idem com `.eu` |

**Atenção à grafia do header** — são APIs diferentes com convenções diferentes:

- Log API → `Api-Key` (A e K maiúsculos)
- OTLP → `api-key` (tudo minúsculo)

A região aparece na URL da conta (`one.eu.newrelic.com`) ou no prefixo da chave (`eu01...`).

---

## Como a chave chega lá sem tocar o arquivo

`kong/kong.compose.yml` e `kong/kong.k8s.yml` carregam o placeholder literal
`<NEW_RELIC_LICENSE_KEY>` dentro dos plugins `http-log` e `opentelemetry`. Ele nunca é
editado à mão — quem substitui é um `sed` rodado **dentro do container**, no momento do
bootstrap, lendo a chave de uma variável de ambiente:

- **docker-compose**: o serviço `kong-bootstrap` recebe `NEW_RELIC_LICENSE_KEY` do `.env`
  (`environment: NEW_RELIC_LICENSE_KEY: "${NEW_RELIC_LICENSE_KEY:-}"`), monta
  `kong/kong.compose.yml` como **`.template`** somente leitura, roda o `sed` escrevendo o
  resultado em `/tmp/kong.yml` — fora do bind mount — e importa esse arquivo.
- **Kubernetes**: o Job `kong-bootstrap` (container `seed`) lê `NEW_RELIC_LICENSE_KEY` de
  `secretKeyRef: {name: newrelic, key: license-key, optional: true}`. O `optional: true`
  é o que mantém o fluxo padrão (sem a Secret `newrelic` criada) funcionando: a variável
  simplesmente não é definida, o `sed` substitui o placeholder por uma string vazia, e o
  `db_import` segue normalmente — só que a New Relic recusa os envios até a chave existir.

Por isso o `kong/kong.*.yml` versionado **nunca contém a chave real** — só o placeholder
— e o repositório pode ser commitado com os plugins ativos sem vazar segredo nenhum.

> **Por que não `envsubst`?** É o caminho mais comum para isso, mas a imagem `kong:3.9`
> (Ubuntu 24.04) não traz `envsubst` — instalar via `apt-get` a cada bootstrap seria lento
> e dependeria de rede. `sed` já vem na imagem e resolve o mesmo problema com uma
> substituição de texto simples.
>
> Kong Vault também não ajuda aqui: o suporte a referências `{vault://env/...}` não está
> implementado para a maioria dos atributos de plugin da comunidade — é por isso que a
> credencial `jwt_secrets` (a chave HS256 do UsersAPI) continua indo literal no arquivo.

---

## Ligando

### 1. Criar a conta e pegar a license key

Conta free em [newrelic.com/signup](https://newrelic.com/signup): 100 GB/mês, 1 usuário
full-platform — mais que suficiente para o desafio. A chave está em
**Profile → API keys**, tipo **INGEST - LICENSE**.

### 2. Guardar a chave (nunca versionar)

**docker-compose:**

```bash
cp .env.example .env
# edite .env:
#   NEW_RELIC_ENABLED=1
#   NEW_RELIC_LICENSE_KEY=<sua-chave>
#   KONG_TRACING_INSTRUMENTATIONS=all
#   KONG_TRACING_SAMPLING_RATE=1.0
```

O `.env` está no `.gitignore`.

**Kubernetes:**

```powershell
kubectl create secret generic newrelic -n fiapgames `
  --from-literal=license-key='<sua-chave>'
```

Comando em vez de manifesto, pela mesma razão da Secret `kong-declarative-config`: nada
de chave real no git.

### 3. Aplicar

Não há arquivo para editar — só recarregar com a chave já no lugar.

**docker-compose:**

```bash
docker compose up -d
docker compose up -d --force-recreate kong-bootstrap
docker compose restart kong
```

**Kubernetes** — o agente dos microsserviços entra pelos patches, no mesmo padrão dos
patches de `imagePullPolicy` do passo 7 do README; o gateway recarrega o Job de seed
(que agora enxerga a Secret `newrelic` e faz a substituição sozinho) e reinicia:

```powershell
kubectl patch deployment catalog-api       -n fiapgames --patch-file k8s/patches/catalog-api-newrelic.json
kubectl patch deployment payments-api      -n fiapgames --patch-file k8s/patches/payments-api-newrelic.json
kubectl patch deployment notifications-api -n fiapgames --patch-file k8s/patches/notifications-api-newrelic.json
kubectl patch deployment user-api          -n fiapgames --patch-file k8s/patches/user-api-newrelic.json

# tracing no gateway (o manifesto vem com "off")
kubectl set env deployment/kong -n fiapgames `
  KONG_TRACING_INSTRUMENTATIONS=all KONG_TRACING_SAMPLING_RATE=1.0

kubectl delete job kong-bootstrap -n fiapgames
kubectl apply -f k8s/kong/
kubectl rollout restart deployment/kong -n fiapgames
```

> Os patches dos microsserviços usam `env` (não `envFrom`) de propósito: `env` faz merge
> por `name`, então as variáveis do New Relic são **somadas** às existentes. `envFrom`
> não tem merge key — um patch nele **substituiria a lista inteira**, apagando os
> ConfigMaps e Secrets que cada serviço já usa.

---

## Como o agente .NET entra nas imagens

Pelo pacote NuGet **`NewRelic.Agent`** (10.53.1), referenciado no `.csproj` de cada API.
Ele se deposita em `/app/newrelic` no publish, então:

- **os Dockerfiles não mudam** — a linha `COPY --from=publish` existente já leva o agente
- **nenhum `wget` é necessário** — a imagem `mcr.microsoft.com/dotnet/aspnet:10.0` é
  Debian-slim e não tem `wget` nem `curl`, o que tornaria o caminho do `.tar.gz` mais caro
- **nenhum código muda** — o agente é ativado por variável de ambiente

Compatibilidade confirmada: .NET 10 exige agente **≥ 10.0.0**, e ASP.NET Core 10.0 é
suportado.

As variáveis, iguais nos 4 serviços (só `NEW_RELIC_APP_NAME` muda):

```
CORECLR_ENABLE_PROFILING=1
CORECLR_PROFILER={36032161-FFC0-4B61-B559-F6C5D41BAE5A}   # GUID fixo da New Relic
CORECLR_NEWRELIC_HOME=/app/newrelic
CORECLR_PROFILER_PATH=/app/newrelic/libNewRelicProfiler.so
NEW_RELIC_LICENSE_KEY=<do Secret / .env>
NEW_RELIC_APP_NAME=fiapgames-catalog-api
NEW_RELIC_APPLICATION_LOGGING_ENABLED=true
NEW_RELIC_APPLICATION_LOGGING_FORWARDING_ENABLED=true
NEW_RELIC_DISTRIBUTED_TRACING_ENABLED=true
```

Com `CORECLR_ENABLE_PROFILING=0` (o default) o CLR **nem carrega** o profiler — o agente
fica completamente inerte, sem custo e sem erro, mesmo sem chave.

---

## Conferindo

**Desligado** (estado padrão) — nada deve aparecer:

```bash
docker compose logs catalog-api | grep -i newrelic     # silêncio
```

`http-log` e `opentelemetry` continuam presentes e ativos no Kong mesmo sem chave — sem
license key válida a New Relic recusa (401/403), visível só no log do plugin, sem impacto
no tráfego. Ver [Como a chave chega lá](#como-a-chave-chega-lá-sem-tocar-o-arquivo).

**Ligado — validado com uma conta real** (o que segue foi de fato observado, não é só o
resultado esperado):

```bash
# 1. o agente .NET carregou e conectou?
docker compose exec catalog-api sh -c \
  "grep -iE 'fully connected|unauthorized' /app/newrelic/logs/newrelic_agent_FiapGames.Catalog.log"
#   Agent dotnetfiapgames-catalog-api connected to collector.newrelic.com:443
#   Agent fully connected.

# 2. a chave chegou de verdade no plugin do Kong (mascarada, só para conferir o tamanho)?
curl -s http://localhost:8001/plugins | python3 -c "
import json,sys
for p in json.load(sys.stdin)['data']:
    if p['name'] in ('http-log','opentelemetry'):
        print(p['name'], len(p['config']['headers'].get('Api-Key') or p['config']['headers'].get('api-key')))
"
#   http-log 40
#   opentelemetry 40

# 3. os endpoints da New Relic aceitam o tráfego (mesma rede que o Kong usa)?
NET=$(docker network ls --format '{{.Name}}' | grep fiapgames | head -1)
docker run --rm --network "$NET" curlimages/curl:latest -s -o /dev/null -w '%{http_code}\n' \
  https://log-api.newrelic.com/log/v1 -X POST -H 'Content-Type: application/json' \
  -H "Api-Key: <sua-chave>" -d '[{"message":"teste manual"}]'
#   202
docker run --rm --network "$NET" curlimages/curl:latest -s -o /dev/null -w '%{http_code}\n' \
  https://otlp.nr-data.net:4318/v1/traces -X POST -H 'Content-Type: application/json' \
  -H "api-key: <sua-chave>" -d '{}'
#   200

# 4. gera tráfego real pelo gateway (fluxo de compra completo)
curl -s http://localhost:8000/health                        # 200, rota pública
curl -s http://localhost:8000/games                         # 401, barrado pelo Kong
# ... cadastro -> login -> criar jogo -> comprar (ver README) ...
```

O agente .NET usa **rejit sob demanda**: só instrumenta o `ControllerActionInvoker` (o
que gera `Transaction`) na primeira chamada real a um controller — e só conta a partir da
chamada seguinte. Se o primeiro teste não aparecer, gere uma segunda rajada de tráfego e
aguarde o próximo ciclo de harvest (a cada 2 minutos; ver o `AgentHealthReporter` no log
do agente).

Confirmado na prática, no fluxo de compra completo (cadastro → login → criar jogo →
comprar → Payments processa → Notifications envia e-mail):

| Serviço | Como recebeu tráfego | Confirmado |
|---|---|---|
| `fiapgames-catalog-api` | HTTP (GET /games, /orders) | 6 Transaction, 15 Span events |
| `fiapgames-users-api` | HTTP (login, cadastro) | 1-2 Transaction, 7-56 Span events |
| `fiapgames-payments-api` | **só fila RabbitMQ** (nunca HTTP) | 1 Transaction, 5 Span events |
| `fiapgames-notifications-api` | **só fila RabbitMQ** (nunca HTTP) | 2 Transaction, 8 Span events |

Payments e Notifications gerarem `Transaction` **sem nunca terem recebido uma requisição
HTTP** é a prova de que o wrapper MassTransit do agente captura o consumo de mensagem —
ou seja, o trace atravessa o RabbitMQ e liga Catalog → Payments → Notifications, que é
exatamente o fluxo de "Compra de Jogo" que o enunciado pede.

No New Relic:

| Onde olhar | O que deve aparecer |
|---|---|
| **Logs** | `SELECT * FROM Log SINCE 10 minutes ago` — o log de acesso do Kong |
| **Logs** | `SELECT count(*) FROM Log FACET response.status` — a distribuição 200/401 |
| **APM & Services** | 4 apps: `fiapgames-{catalog,payments,notifications,users}-api` |
| **Distributed tracing** | o trace de Compra de Jogo, com spans do gateway + 4 serviços |
| **Dashboards** | `SELECT average(duration) FROM Transaction FACET appName` |

### O teste que justifica instrumentar os serviços

O gateway barra na **borda**, não por dentro. De dentro da rede Docker o CatalogAPI está
aberto — foi medido:

```bash
NET=$(docker network ls --format '{{.Name}}' | grep fiapgames | head -1)
docker run --rm --network "$NET" curlimages/curl:latest -s -o /dev/null -w "%{http_code}\n" \
  http://catalog-api:8080/games
# 200 — sem token, contornando o Kong
```

Esse request **nunca toca o Kong**, então nenhum plugin de log do gateway o registra. Com
o agente dentro do Catalog, ele passa a aparecer como `Transaction` em
`fiapgames-catalog-api` **sem** span correspondente no gateway — que é a assinatura exata
de um bypass. Vale como evidência no vídeo e no relatório de entrega.

---

## Limitações

1. **Kong 3.9 OSS não exporta logs nem métricas por OTLP** — só traces. Unificar tudo em
   OTLP exigiria Kong Enterprise 3.13+.
2. **Formato do `http-log`.** Ele envia o log serializer do Kong, com objetos aninhados
   (`request`, `response`, `latencies`, `route`, `service`). A Log API aceita array de
   objetos, mas o aninhamento **pode não virar atributo consultável automaticamente** —
   se as queries por `response.status` vierem vazias, é preciso achatar com
   `custom_fields_by_lua`. Verificar com dados reais antes de montar o dashboard.
3. **Limites da Log API**: 1 MB por POST, 255 atributos por evento, 4.094 caracteres por
   valor. Daí `queue.max_batch_size: 50`.
4. **`sampling_rate: 1.0`** captura 100% dos traces — correto para demonstração, caro em
   produção.
5. **O agente aumenta a imagem** em ~30–50 MB por serviço e adiciona overhead de startup.
6. **Observabilidade torna o bypass visível, não impossível.** Fechá-lo de verdade pede o
   CatalogAPI validando JWT no próprio código (como o UsersAPI já faz) e/ou
   NetworkPolicies restringindo quem fala com os serviços no cluster.
