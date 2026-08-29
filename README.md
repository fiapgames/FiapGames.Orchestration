# FiapGames.Orchestration

Repositório de orquestração do FiapGames (Tech Challenge Fases 2 e 3). Não contém código de aplicação — apenas o `docker-compose.yml` que sobe todos os microsserviços juntos, compartilhando um único RabbitMQ, a configuração do **API Gateway (Kong)** e instruções de deploy no Kubernetes.

Assume que os repositórios dos microsserviços estão clonados **lado a lado** com este:

```
projeto pos parte 2/
├── Fiap.Games.Users/           <- UsersAPI (pasta do projeto: User.Games.Fiap/)
├── FiapGames.Catalog/
├── FiapGames.Contracts/
├── FiapGames.Notifications/
├── FiapGames.Orchestration/    <- este repositório
├── FiapGames.Payments/
└── FiapGames.Web/              <- front-end (React + Vite)
```

## O que vive aqui

```
FiapGames.Orchestration/
├── docker-compose.yml          sobe tudo localmente, gateway incluído
├── .env.example                template das variáveis (o .env real é gitignored)
├── kind-config.yaml            publica as portas do gateway no host (não é manifesto k8s)
├── kong/                       configuração declarativa do gateway
│   ├── kong.k8s.yml            rotas + políticas (canônico, ambiente Kubernetes)
│   ├── kong.compose.yml        idem, ambiente docker-compose
│   ├── init.sql                cria a base do Konga
│   └── NEWRELIC.md             guia dos 3 pilares de observabilidade (desligado)
└── k8s/
    ├── namespace.yaml
    ├── rabbitmq.yaml           \
    ├── postgres.yaml            |  infraestrutura compartilhada
    ├── sqlserver.yaml           |  (os repos dos microsserviços não trazem isso)
    ├── sqlserver-users.yaml     |
    ├── mailhog.yaml            /
    ├── postgres-kong.yaml      banco PRÓPRIO do gateway (postgres:11.16)
    ├── kong/                   manifestos do gateway (prefixo numérico = ordem de apply)
    │   ├── 00-kong-db-config.yaml
    │   ├── 01-kong-bootstrap-job.yaml
    │   ├── 02-kong.yaml
    │   └── 03-konga.yaml
    └── patches/                patches aplicados nos Deployments dos repos irmãos
        ├── *-image-pull-policy.json    imagePullPolicy para teste local com Kind
        └── *-newrelic.json             agente APM (só ao ligar observabilidade)
```

## Serviços

| Serviço | Porta (host) | Depende de |
|---|---|---|
| `rabbitmq` | 5672 (AMQP), 15672 (management UI) | — |
| `sqlserver-catalog` | 1433 | — |
| `sqlserver-users` | 1434 | — |
| `postgres-payments` | 5432 | — |
| `postgres-notifications` | 5433 | — |
| `mailhog` | 1025 (SMTP), 8025 (web UI) | — |
| `catalog-api` | 8080 | rabbitmq, sqlserver-catalog |
| `payments-api` | 8081 | rabbitmq, postgres-payments |
| `notifications-api` | 8082 | rabbitmq, postgres-notifications, mailhog |
| `users-api` | 8083 | rabbitmq, sqlserver-users |
| `postgres-kong` | — (só interno) | — |
| `kong` | **8000** (proxy), 8001 (Admin API), 8002 (Kong Manager), 8100 (status/métricas) | postgres-kong |
| `konga` | 1337 | postgres-kong, kong |

> As portas 8080–8083 continuam publicadas para debug, mas **o endereço de uso normal é `http://localhost:8000`** — o gateway. Bater direto em 8080 contorna a validação de JWT.

## API Gateway (Kong)

O Kong é a **única porta de entrada** do sistema: recebe todas as requisições externas, valida o token JWT e roteia para o UsersAPI e o CatalogAPI. Rotas, políticas e credenciais ficam versionadas em [`kong/kong.k8s.yml`](kong/kong.k8s.yml).

### Mapa de rotas

Roteamento **passthrough**: os paths originais de cada serviço são preservados, então o gateway é transparente para quem já conhecia as APIs.

| Rota (Kong) | Método | Path | Destino | JWT |
|---|---|---|---|---|
| `users-register` | `POST` | `/api/users` | user-api | **público** (cadastro) |
| `users-login` | `POST` | `/api/users/login` | user-api | **público** (emite o token) |
| `users-refresh` | `POST` | `/api/users/refresh` | user-api | **público** |
| `users-preflight` | `OPTIONS` | `/api/users` (prefixo) | user-api | **público** (preflight CORS) |
| `users-read` | `GET` | `/api/users`, `/api/users/{id}` | user-api | exigido |
| `catalog-health` | `GET`, `OPTIONS` | `/health` | catalog-api | **público** (HealthBadge do front) |
| `catalog-games` | todos | `/games`, `/games/{id}`, `/games/{id}/purchase` | catalog-api | exigido |
| `catalog-orders` | todos | `/orders`, `/orders/{id}` | catalog-api | exigido |
| `catalog-library` | todos | `/library/{userId}` | catalog-api | exigido |

A rota `users-preflight` e o `OPTIONS` em `catalog-health` existem porque as demais rotas do Users restringem `methods` — sem elas o preflight do navegador tomava 404 e o **login do front não funcionava**. Detalhes em [CORS e o preflight](#cors-e-o-preflight--a-parte-mais-fácil-de-errar).

As três rotas de `POST /api/users*` são públicas por necessidade: são elas que criam a conta e emitem o token — protegê-las seria um problema de galinha e ovo. Todo o resto do Catalog é protegido, e isso **fecha um buraco real**: o CatalogAPI não tem `AddAuthentication` nem `[Authorize]` em lugar nenhum do código, então até agora `POST /games/{id}/purchase` estava aberto para qualquer um. O gateway é o único ponto de enforcement.

### Políticas ativas

| Plugin | Configuração | Para quê |
|---|---|---|
| `jwt` | `claims_to_verify: [exp]`, `run_on_preflight: false` | valida assinatura e expiração |
| `rate-limiting` | 100/min, `policy: local`, `limit_by: ip` | protege o tráfego |
| `correlation-id` | `X-Correlation-ID`, ecoado na resposta | rastrear uma compra pelos 4 serviços |
| `prometheus` | em `:8100/metrics` | base da observabilidade (item 3) |

### Como o JWT é validado

O UsersAPI assina com **HS256 simétrico** (`AuthService.GenerateAccessToken`), então o Kong valida com a mesma chave compartilhada:

| No token (UsersAPI) | No Kong (`consumers.jwt_secrets`) |
|---|---|
| `Jwt__Issuer` = `User.Games.Fiap` | `key: "User.Games.Fiap"` |
| `HmacSha256` | `algorithm: HS256` |
| `Jwt__SecretKey` (bytes UTF-8 crus) | `secret:` com a mesma string |

O plugin casa token e credencial pelo claim **`iss`** (`key_claim_name`), por isso a `key` precisa ser exatamente o issuer. O .NET usa `Encoding.UTF8.GetBytes` e o Kong trata o `secret` igual — sem decodificar base64.

Três detalhes que **não são opcionais** e são fáceis de errar:

- `claims_to_verify: ["exp"]` — sem isso, **token expirado passa**. O campo não tem valor default.
- `run_on_preflight: false` — o default é `true`, e aí o preflight `OPTIONS` do navegador (que não leva `Authorization`) tomaria 401 e todas as chamadas do front quebrariam.
- `limit_by: ip` — o default é `consumer`, e como existe um único `jwt_secret`, *todos* os usuários logados viram o mesmo consumer: o rate limit seria um balde global em vez de por cliente.

O plugin `jwt` do Kong **não valida `aud`**. O UsersAPI continua validando por conta própria (`ValidateAudience = true`); o Catalog não valida nada — para ele o gateway é a única barreira.

### Por que modo banco (e não DB-less)

O Konga e o Kong Manager administram o Kong pela **Admin API**, e em DB-less ela é read-only (`405` em `POST/PUT/PATCH/DELETE`). Para as UIs funcionarem, o Kong precisa de banco.

Isso tensiona o requisito de ter a configuração versionada no repositório, já que em modo banco a config passa a viver no Postgres. A reconciliação é o **`kong config db_import`**: o `kong.yml` continua sendo a fonte da verdade e um Job/serviço o carrega no banco.

**Consequência prática — drift.** Editar pela UI **não** volta para o repo, e o `db_import` só faz *upsert* de entidades que têm chave natural (`name` em services e routes, `username` em consumers) — ele nunca apaga o que sumiu do arquivo. Então:

- mudança para valer → editar o `kong.yml`, recarregar o seed **e reiniciar o Kong** (ver abaixo)
- mudança feita na UI que você quer preservar → `kong config db_export` para trazer de volta
- entidade **removida** do arquivo → continua no banco; precisa apagar pela UI/Admin API ou zerar o banco

**Entidades sem chave natural precisam de `id` explícito.** A credencial em `consumers[].jwt_secrets[]` não tem chave natural, então sem um `id` fixo o Kong gera um UUID novo a cada import e a **segunda execução do seed falha** com `UNIQUE violation detected on '{key="User.Games.Fiap"}'`. É por isso que o `kong.yml` fixa `id: fc900000-0000-4000-8000-000000000001` — com ele, reimportar atualiza a mesma linha e o seed fica idempotente.

### Alterando rotas ou políticas

```bash
# 1. edita os DOIS arquivos versionados
#    kong/kong.compose.yml  e  kong/kong.k8s.yml

# 2. valida antes de aplicar
docker run --rm -e KONG_DATABASE=off -v "${PWD}/kong:/cfg" kong:3.9 kong config parse /cfg/kong.compose.yml

# 3. recarrega a config no banco
docker compose up -d --force-recreate kong-bootstrap

# 4. OBRIGATÓRIO: faz o Kong reler o banco
docker compose restart kong
```

> **O passo 4 não é opcional.** O `db_import` grava direto no Postgres, mas **não emite os eventos de invalidação de cache** que o Kong usa para saber que a config mudou — um nó já rodando continua servindo o router antigo indefinidamente. Isso foi observado na prática: depois de adicionar uma rota nova, o Admin API (`/routes`) já mostrava a rota corretamente no banco enquanto o proxy ainda respondia `404 no Route matched`. O `restart` (ou `kong reload`) resolve. No Kubernetes o equivalente é `kubectl rollout restart deployment/kong -n fiapgames`.

**Zerando só o banco do gateway** (necessário se você mudar a identidade de alguma entidade, ou para reconstruir do zero sem derrubar o resto):

```powershell
docker compose rm -sf kong kong-bootstrap konga konga-prepare postgres-kong
docker volume rm fiapgamesorchestration_postgres-kong-data
docker compose up -d kong konga
```

### Banco próprio, Postgres 11.16 fixado

O gateway é um microsserviço como os outros e tem **banco próprio** ([`k8s/postgres-kong.yaml`](k8s/postgres-kong.yaml)), separado do `postgres:16` que serve Payments e Notifications — mesmo padrão de `sqlserver` (Catalog) vs `sqlserver-users` (Users).

A versão **11.16 é fixada de propósito e não deve ser atualizada**: o Konga usa um driver `sails-postgresql` antigo que quebra em Postgres moderno.

| | `k8s/postgres.yaml` | `k8s/postgres-kong.yaml` |
|---|---|---|
| Imagem | `postgres:16` | **`postgres:11.16`** |
| Bancos | `fiapgames-payments`, `fiapgames-notifications` | `kong`, `konga` |
| Usado por | Payments, Notifications | Kong, Konga |

### Duas UIs de administração

- **Kong Manager** (`http://localhost:8002`) — GUI **oficial**, embutida na própria imagem `kong:3.4+`, sem container nem banco extra. Mantida pela Kong.
- **Konga** (`http://localhost:1337`) — GUI da comunidade. No primeiro acesso, criar o usuário admin na tela e cadastrar uma *Connection* apontando para `http://kong:8001` (compose) ou `http://kong.fiapgames.svc.cluster.local:8001` (Kubernetes).

> O Konga está **arquivado** upstream e seu suporte oficial vai até o Kong 2.x — a imagem `pantsel/konga:latest` é de **maio de 2020**. Está aqui porque a aula pede. Se alguma tela quebrar com o Kong 3.x, há dois caminhos: trocar a tag para `pantsel/konga:next` (build da branch de desenvolvimento, um pouco mais nova) ou simplesmente usar o Kong Manager, que cobre a mesma função e é mantido.

### Segurança — o que está aberto de propósito

Isto é um ambiente **local de desenvolvimento**. Estão publicados no host sem autenticação:

- `localhost:8001` — Admin API do Kong: quem alcança, reconfigura o gateway
- `localhost:8002` — Kong Manager: a versão OSS **não tem autenticação nenhuma**
- `localhost:1337` — Konga (esse tem login próprio)

Fora de um cluster local, nada disso deveria estar exposto.

### O que o bypass revelou

Vale registrar porque explica uma decisão do `docker-compose.yml`. Enquanto as APIs publicavam suas portas no host, foi medido o mesmo request pelos dois caminhos:

| Request sem token | via gateway `:8000` | direto na API |
|---|---|---|
| `GET /games` | **401** | `:8080` → **200** |
| `GET /orders` | **401** | `:8080` → **200** |
| `POST /games` | **401** | `:8080` → **jogo criado** |
| `POST /games/{id}/purchase` | **401** | `:8080` → **202, compra feita** |
| `GET /api/users` | **401** | `:8083` → **401** |

Duas conclusões:

**O UsersAPI se defende sozinho.** Dá 401 mesmo furando o gateway, porque valida JWT no próprio código (`AddJwtBearer` no `Program.cs`). É defesa em profundidade real — o gateway valida, e o serviço valida de novo.

**O CatalogAPI não tem defesa alguma.** Sem `AddAuthentication`, sem `[Authorize]`: o gateway é a **única** barreira. Contorná-lo dava acesso total, inclusive comprar sem estar autenticado.

Por isso as portas 8080–8083 foram comentadas no compose. O Kubernetes já estava correto — o `kind-config.yaml` publica só as portas do gateway, então `catalog-api` e `user-api` nunca foram alcançáveis do host. Agora os dois ambientes têm a mesma postura.

> A correção de fundo seria o CatalogAPI validar JWT também, em vez de depender só da borda. Isso é mudança no repo do Catalog, fora do escopo desta entrega — mas é a recomendação.

### Observabilidade

O plugin `prometheus` já está ativo e expõe métricas em `:8100/metrics` (379 séries). Os plugins `http-log` e `opentelemetry` também já estão ativos no `kong.*.yml`, mandando dados para a New Relic assim que uma license key existir — sem chave, ficam inofensivos (a New Relic recusa com 401/403, visível só no log do Kong). Ver a seção [Observabilidade (New Relic)](#observabilidade-new-relic) abaixo.

### Dois arquivos declarativos

O upstream difere entre os ambientes de forma irredutível — no compose os serviços resolvem por nome de container na porta 8080, no cluster pelo FQDN do Service na porta 80 — e o Kong **não interpola variáveis de ambiente** em config declarativa. Daí dois arquivos irmãos:

```bash
# devem divergir SOMENTE nas 3 linhas "url:"
diff kong/kong.k8s.yml kong/kong.compose.yml
```

Mudou uma rota ou política? Mude nos dois. `kong.k8s.yml` é o canônico.

### CORS e o preflight — a parte mais fácil de errar

O gateway **não** usa o plugin `cors` de propósito: o Users e o Catalog já resolvem CORS em código (`UseCors`), e somar o plugin duplicaria o header `Access-Control-Allow-Origin` nas respostas 200 — o que os navegadores rejeitam. Quem responde os headers `Access-Control-*` é a aplicação; o papel do gateway é só deixar o preflight passar.

Isso exige **duas** coisas, e as duas foram descobertas quebrando na prática:

**1. `run_on_preflight: false` no plugin `jwt`.** O default é `true`. Como o `OPTIONS` de preflight não carrega `Authorization` (por definição — o navegador o envia antes de saber se pode), com o default ele tomaria 401 e nenhuma chamada do front funcionaria.

**2. Rotas que aceitem o método `OPTIONS`.** Este é o pega mais sutil. As rotas do Users restringem `methods` (`POST` no login/cadastro/refresh, `GET` na leitura), então um `OPTIONS` não casava com **nenhuma** e o Kong devolvia `404 no Route matched` — bloqueando o **login do front antes da requisição real sair**. Daí a rota dedicada `users-preflight` (`paths: /api/users`, `methods: [OPTIONS]`), cujo prefixo cobre `/login`, `/refresh`, `/` e `/{id}`.

O mesmo valia para o `/health`: o `httpClient.ts` do front manda `Content-Type: application/json` em **todo** request, inclusive `GET`, e esse header não é CORS-safelisted — então o navegador dispara preflight até no health check. Por isso `catalog-health` aceita `["GET", "OPTIONS"]`.

As rotas do Catalog (`/games`, `/orders`, `/library`) não declaram `methods`, então aceitam qualquer método e nunca tiveram o problema.

Deixar o `OPTIONS` passar não abre porta dos fundos: o preflight não carrega credencial nem corpo, e tentar usá-lo para chegar num handler real devolve `405`.

**Efeito colateral que permanece:** um 401 gerado *pelo Kong* não passa pela aplicação, então não leva header CORS (verificado: `Access-Control-Allow-Origin` ausente na resposta 401). No navegador isso aparece como erro de CORS em vez de 401 — e, como o `fetch` rejeita antes de devolver uma resposta, o `if (response.status === 401)` do `httpClient.ts` não roda, então a sessão expirada não é limpa automaticamente. Não afeta `curl`. A correção limpa seria desligar o CORS in-app e deixar o Kong ser o dono via plugin `cors` — mexe nos repos do Catalog e do Users, fora do escopo.

### Limitação: identidade não trafega para o Catalog

O Catalog recebe o `userId` pelo body ou pela rota, nunca do token, e não lê nenhum header. Como existe um único `jwt_secret`, o `X-Consumer-ID` que o Kong injeta é igual para todos e não serve como identidade. Ou seja: **o gateway garante que o token é válido, mas o Catalog continua confiando no `userId` que o cliente enviar.** Propagar o claim `sub` exigiria o plugin `pre-function` ou mudança no Catalog.

## Observabilidade (New Relic)

Stack escolhida para o item 3 do Tech Challenge: **Opção B — plataforma de APM gerenciada, New Relic**. Cobre os três pilares exigidos, no gateway **e** nos quatro microsserviços.

> **Estado atual: desligado.** Tudo está versionado e inerte, esperando uma license key. Sem ela nada quebra e o ambiente sobe exatamente como antes. Guia completo de ativação: [`kong/NEWRELIC.md`](kong/NEWRELIC.md).

| Pilar | Gateway (Kong 3.9 OSS) | Microsserviços (.NET 10) |
|---|---|---|
| **Métricas** | plugin `prometheus` — **já ativo** | agente APM (automático) |
| **Logs** | plugin `http-log` → Log API | agente, *logs-in-context* |
| **Traces** | plugin `opentelemetry` → OTLP | agente, distributed tracing (W3C) |

**New Relic não substitui o Prometheus — ela o consome.** O plugin é a *fonte* das métricas; a New Relic é um dos *destinos* (o agente Prometheus dela faz scrape de `:8100/metrics`). Manter o plugin não amarra o projeto ao Grafana.

### Por que três mecanismos e não só OTLP

Seria elegante mandar tudo por OTLP com um plugin só, mas **não dá nesta versão**: exportar logs e métricas pelo plugin `opentelemetry` só existe a partir da versão 3.13 do plugin, que é Kong **Enterprise**. O Kong OSS para em 3.9.3. Aqui o `opentelemetry` faz apenas traces.

Também não usamos a receita oficial da New Relic (`file-log` → stdout → integração Kubernetes): ela pressupõe o Ingress Controller com CRDs, exige **Helm** (não instalado) e não funciona no docker-compose. O `http-log` postando direto na Log API resolve nos dois ambientes.

### Como o agente entra nas imagens

Pelo pacote NuGet `NewRelic.Agent` (10.53.1), referenciado no `.csproj` de cada API. Ele se deposita em `/app/newrelic` no publish, então **os Dockerfiles não mudam** e **nenhum código muda** — a ativação é só por variável de ambiente. Isso importa porque a imagem `mcr.microsoft.com/dotnet/aspnet:10.0` é Debian-slim e não tem `wget` nem `curl`, o que encareceria o caminho do `.tar.gz`.

Com `CORECLR_ENABLE_PROFILING=0` (o default, vindo de `NEW_RELIC_ENABLED` no `.env`) o CLR **nem carrega** o profiler: agente completamente inerte, sem custo e sem erro.

### Validado com conta real

O caminho inteiro — agente nos 4 microsserviços **e** os dois plugins do gateway — foi validado com uma license key de verdade, não só com chave fictícia:

```
Agent dotnetfiapgames-catalog-api connected to collector.newrelic.com:443
Agent fully connected.
```

Confirmado nos 4 serviços. No fluxo de compra completo (cadastro → login → criar jogo → comprar → Payments processa → Notifications envia e-mail), todos os quatro reportaram `Transaction`/`Span` — incluindo **Payments e Notifications, que nunca recebem uma requisição HTTP**: eles geraram transações só por **consumir mensagem do RabbitMQ**, capturadas pelo wrapper MassTransit do agente. Ou seja, o trace atravessa a fila e liga Catalog → Payments → Notifications num único trace distribuído, exatamente o fluxo de "Compra de Jogo" que o enunciado pede.

Do lado do gateway, os endpoints da New Relic responderam `202` (Log API) e `200` (OTLP) para requisições de teste feitas da mesma rede Docker que o Kong usa, e o Admin API confirmou a chave de 40 caracteres carregada nos dois plugins — sem erro nenhum no log do Kong depois do reload.

> Os logs do agente .NET ficam **em arquivo dentro do container**, não em stdout: `/app/newrelic/logs/`. É o primeiro lugar a olhar em caso de problema — `docker compose exec catalog-api sh -c "tail /app/newrelic/logs/*.log"`.
>
> O agente usa **rejit sob demanda**: só instrumenta o `ControllerActionInvoker` (o que gera `Transaction`) na primeira chamada real a um controller, e só conta a partir da chamada seguinte. Se o primeiro teste não aparecer, gere mais uma rajada de tráfego e aguarde o próximo ciclo de harvest (a cada 2 minutos).

### Gestão da chave — nunca escrita em arquivo versionado

A chave nunca é editada manualmente em `kong/kong.*.yml`. Esses arquivos carregam só o placeholder `<NEW_RELIC_LICENSE_KEY>`, e um `sed` — rodado **dentro do container**, no momento do bootstrap — troca esse placeholder pela chave real, lida de uma variável de ambiente:

- **docker-compose**: vem do `.env` (gitignored, template em [`.env.example`](.env.example)). O serviço `kong-bootstrap` monta `kong/kong.compose.yml` como somente leitura, escreve o resultado substituído em `/tmp/kong.yml` — fora do bind mount — e importa esse arquivo.
- **Kubernetes**: vem da Secret `newrelic`, criada por comando (nunca manifesto):
  ```powershell
  kubectl create secret generic newrelic -n fiapgames --from-literal=license-key='<sua-chave>'
  ```
  O Job de bootstrap referencia essa chave com `optional: true` — sem a Secret criada (o padrão de fábrica), a variável simplesmente não existe, o `sed` substitui por uma string vazia, e o `db_import` continua funcionando normalmente.

Por que não `envsubst` (o caminho mais comum)? A imagem `kong:3.9` é Ubuntu 24.04 e não traz `envsubst` instalado — precisaria de `apt-get` a cada bootstrap, dependendo de rede. `sed` já vem na imagem.

No Kubernetes o agente dos microsserviços entra por `kubectl patch`, no mesmo padrão dos patches de `imagePullPolicy` do passo 7 — os arquivos estão em `k8s/patches/*-newrelic.json`. Eles usam `env` e não `envFrom` de propósito: `env` faz merge por `name`, somando as variáveis; um patch em `envFrom` **substituiria a lista inteira** e apagaria os ConfigMaps e Secrets que cada serviço já usa.

### O ponto cego que isso fecha

O gateway barra na **borda**, não por dentro. Medido: de dentro da rede Docker, `GET http://catalog-api:8080/games` devolve **200 sem token**, e `POST /games/{id}/purchase` devolve **202** — porque o CatalogAPI não valida JWT no código. Esses acessos **nunca tocam o Kong**, então nenhum plugin de log do gateway os registra.

Com o agente dentro do Catalog, eles passam a aparecer como `Transaction` em `fiapgames-catalog-api` **sem** span correspondente no gateway — a assinatura exata de um bypass. Foi o argumento decisivo para instrumentar os serviços e não só o gateway.

## Executando localmente

```bash
docker compose up -d --build
```

Isso builda a imagem de cada API a partir do Dockerfile do respectivo repositório irmão, sobe um único RabbitMQ compartilhado, o banco de cada serviço, e o Mailhog (simula envio de e-mail do Notifications).

Endpoints úteis:

**Pelo gateway (uso normal):**

- API: `http://localhost:8000` — `/api/users`, `/games`, `/orders`, `/library`, `/health`
- Kong Manager (GUI oficial): `http://localhost:8002`
- Konga (GUI da comunidade): `http://localhost:1337`
- Kong Admin API: `http://localhost:8001`
- Métricas do Kong: `http://localhost:8100/metrics`

**Infraestrutura:**

- RabbitMQ management: `http://localhost:15672` (usuário `fiapgames-admin`, senha `FiapGames@Admin123`)
- Mailhog (e-mails simulados): `http://localhost:8025`

**As APIs não publicam porta no host.** As portas 8080–8083 estão comentadas no `docker-compose.yml` de propósito, para que o gateway seja de fato a única entrada — igual ao que já acontecia no Kubernetes. Para debug direto (por exemplo abrir o `/swagger` do Catalog), descomente o bloco `ports:` do serviço em questão e rode `docker compose up -d <serviço>`.

> Isso não é preciosismo. Medido antes de fechar: com a porta publicada, `POST http://localhost:8080/games/{id}/purchase` **comprava um jogo sem token nenhum**, porque o CatalogAPI não tem autenticação no código e o gateway era a única barreira. Detalhes na seção [O que o bypass revelou](#o-que-o-bypass-revelou).

Antes de subir, vale validar a config declarativa do gateway sem iniciar nada:

```powershell
docker run --rm -e KONG_DATABASE=off -v "${PWD}\kong:/cfg" kong:3.9 kong config parse /cfg/kong.compose.yml
# parse successful
```

> `KONG_DATABASE=off` não é opcional: sem ele o CLI assume o default `postgres` e tenta conectar num banco **antes** de validar o arquivo, falhando com `failed to retrieve PostgreSQL server_version_num: connection refused`.

Confira também que o seed rodou (o `kong-bootstrap` roda uma vez e sai):

```bash
docker compose ps            # kong-bootstrap deve estar Exited (0)
docker compose logs kong-bootstrap
curl -s http://localhost:8001/routes    # o que foi carregado no banco
```

### Testando os dois fluxos completos (cadastro + compra)

Validado de ponta a ponta com os 4 serviços reais rodando juntos, sem nenhuma simulação manual de evento. **Tudo passa pelo gateway (`:8000`)** — o que também demonstra a validação de JWT.

```bash
# 0. rota protegida SEM token -> 401 do próprio Kong, a requisição nem chega no Catalog
curl -i http://localhost:8000/games

# 1. cadastra um usuário (rota pública) -> publica UserCreatedEvent
#    -> Notifications manda e-mail de boas-vindas
curl -X POST http://localhost:8000/api/users -H "Content-Type: application/json" \
  -d '{"nome":"Maria Silva","email":"maria@example.com","password":"SenhaForte@123"}'
# confira em http://localhost:8025 (Mailhog) o e-mail de boas-vindas

# 2. faz login (rota pública) e guarda o access token
TOKEN=$(curl -s -X POST http://localhost:8000/api/users/login -H "Content-Type: application/json" \
  -d '{"email":"maria@example.com","password":"SenhaForte@123"}' \
  | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p')
echo "$TOKEN"

# 3. cria um jogo no Catalog — agora COM token
curl -X POST http://localhost:8000/games -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title":"Elden Ring","description":"Souls-like","price":49.90,"genre":"RPG"}'

# 4. compra o jogo (troque {gameId} e {userId} pelos ids retornados acima)
#    -> Catalog publica OrderPlacedEvent -> Payments processa -> publica PaymentProcessedEvent
#    -> Catalog atualiza o pedido/biblioteca e Notifications manda e-mail de confirmação
curl -X POST http://localhost:8000/games/{gameId}/purchase -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"userId":"{userId}"}'

# 5. acompanha o pedido até virar Approved/Rejected
curl http://localhost:8000/orders/{orderId} -H "Authorization: Bearer $TOKEN"

# 6. confere a biblioteca do usuário — o Catalog busca nome/e-mail reais no UsersAPI
#    via request/response no RabbitMQ (UserLookupRequested/Responded) antes de responder
curl http://localhost:8000/library/{userId} -H "Authorization: Bearer $TOKEN"

# 7. token adulterado -> 401
curl -i http://localhost:8000/games -H "Authorization: Bearer aaa.bbb.ccc"
```

### Conferindo as políticas do gateway

```bash
# correlation-id ecoado na resposta (rastreia a requisição pelos 4 serviços)
curl -is http://localhost:8000/health | grep -i correlation

# rate limiting: aparecem 429 depois de 100 requisições no mesmo minuto
for i in $(seq 1 130); do
  curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8000/health
done | sort | uniq -c

# métricas do Kong (latência, contagem por status code, taxa de erro)
curl -s http://localhost:8100/metrics | head -40
```

Encerrar tudo:

```bash
docker compose down -v
```

## Deploy no Kubernetes

> **Sobre o API Gateway:** o Kong entrou nesta fase e **exige recriar o cluster** — o `kind-config.yaml` publica as portas do gateway no host via `extraPortMappings`, e isso só pode ser definido na criação do cluster. Se você já tem o cluster `fiapgames` de antes, rode `kind delete cluster --name fiapgames` e comece do passo 1. Como toda a infra usa `emptyDir`, não há dado a preservar.

> **Status atual: os 4 microsserviços foram testados no cluster Kind.** O `Fiap.Games.Users` originalmente trazia sua própria pasta `k8s/` isolada (namespace `games-fiap`, RabbitMQ e SQL Server próprios) — foi reconciliada para usar o namespace e a infraestrutura compartilhados (`fiapgames`), do mesmo jeito que os outros três. Os manifestos de infra e RabbitMQ próprios do Users foram removidos (`00-namespace.yaml`, `rabbitmq.yaml`, `sqlserver.yaml`, `kustomization.yaml`); um novo `sqlserver-users.yaml` (SQL Server dedicado do Users, já que cada serviço tem seu próprio banco) foi adicionado aqui, em `k8s/`.

Cada microsserviço mantém seus próprios manifestos (`Deployment`, `ConfigMap`/`Secret`, e no caso do Catalog e do Users também `Service`) em `k8s/` no respectivo repositório. Esses manifestos assumem que a infraestrutura compartilhada (RabbitMQ, Postgres, SQL Server, Mailhog) já existe no cluster com hostnames fixos:

- `rabbitmq.fiapgames.svc.cluster.local` (Payments, Notifications, Catalog, Users)
- `postgres.fiapgames.svc.cluster.local` (um único Postgres compartilhado — Payments e Notifications usam bases diferentes nele: `fiapgames-payments` e `fiapgames-notifications`)
- `sqlserver.fiapgames.svc.cluster.local` (Catalog)
- `sqlserver-users.fiapgames.svc.cluster.local` (Users — banco próprio, separado do SQL Server do Catalog)
- `mailhog.fiapgames.svc.cluster.local` (Notifications)
- `postgres-kong.fiapgames.svc.cluster.local` (Kong e Konga — `postgres:11.16`, separado do Postgres dos outros serviços)

E o gateway resolve os dois serviços HTTP por estes nomes (é o que está em `kong/kong.k8s.yml`):

- `user-api.fiapgames.svc.cluster.local:80`
- `catalog-api.fiapgames.svc.cluster.local:80`

Nenhum repositório de microsserviço traz manifesto de Deployment/Service para essa infraestrutura — por isso os manifestos de infra (`rabbitmq.yaml`, `postgres.yaml`, `sqlserver.yaml`, `sqlserver-users.yaml`, `mailhog.yaml`, `postgres-kong.yaml`) vivem aqui, em `k8s/`. O Users também tem um `migration-job.yaml` (`Job` do Kubernetes que roda `dotnet ... --migrate` uma vez antes do Deployment subir) — os outros três serviços aplicam as migrations automaticamente no startup do próprio processo, o Users prefere um Job separado (evita corrida entre múltiplas réplicas migrando ao mesmo tempo).

### Passo a passo testado (cluster local com Kind)

```bash
# 1. cria o cluster local JÁ COM as portas do gateway publicadas no host
#    (extraPortMappings: 8000 proxy, 8001 admin, 8002 Kong Manager, 8100 métricas, 1337 Konga)
#    sem isso, NodePort não é alcançável do host no Docker Desktop/Windows — foi por isso
#    que o nodePort 30080 do catalog-api nunca funcionou e caímos em port-forward
#    se você já tem um cluster "fiapgames" criado sem esse config, precisa recriar:
#      kind delete cluster --name fiapgames
#    o arquivo fica na raiz (e não em k8s/) porque "kubectl apply -f k8s/" tentaria
#    aplicá-lo como objeto do Kubernetes e falharia — é config do kind, não recurso
kind create cluster --config kind-config.yaml

# 2. sobe a infraestrutura compartilhada
#    (namespace + rabbitmq + postgres + postgres-kong + sqlserver + sqlserver-users + mailhog)
#    namespace.yaml precisa ir primeiro e separado: "kubectl apply -f k8s/" aplica os arquivos
#    em ordem alfabética, e "mailhog.yaml" vem antes de "namespace.yaml" nessa ordem — sem esse
#    apply em separado, ele falha com "namespaces \"fiapgames\" not found"
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/

# 3. builda as imagens das APIs (via docker compose, reaproveitando os Dockerfiles dos repositórios irmãos)
docker compose build

# 4. tageia as imagens com os nomes usados nos manifests de cada repositório
docker tag fiapgamesorchestration-catalog-api:latest brendhom/fiapgames-catalog-api:latest
docker tag fiapgamesorchestration-payments-api:latest lucasceifador/fiapgames-payments-api:latest
docker tag fiapgamesorchestration-notifications-api:latest lucasceifador/fiapgames-notifications-api:latest
docker tag fiapgamesorchestration-users-api:latest user-games-fiap:latest

# 5. carrega as imagens direto no cluster kind (sem precisar de um registry)
kind load docker-image brendhom/fiapgames-catalog-api:latest --name fiapgames
kind load docker-image lucasceifador/fiapgames-payments-api:latest --name fiapgames
kind load docker-image lucasceifador/fiapgames-notifications-api:latest --name fiapgames
kind load docker-image user-games-fiap:latest --name fiapgames

# 6. aplica os manifestos de cada microsserviço
kubectl apply -f ../FiapGames.Catalog/k8s/
kubectl apply -f ../FiapGames.Payments/k8s/
kubectl apply -f ../FiapGames.Notifications/k8s/
kubectl apply -f ../Fiap.Games.Users/k8s/

# 7. como as imagens não estão publicadas num registry real, force o cluster a usar
#    a imagem carregada localmente em vez de tentar puxar do Docker Hub
#    (o user-api.yaml e o migration-job.yaml do Users já vêm com imagePullPolicy: IfNotPresent, não precisam de patch)
#    os patches ficam em arquivo (k8s/patches/) em vez de JSON inline porque aspas duplas
#    dentro de aspas simples se perdem ao passar para o kubectl.exe no PowerShell
kubectl patch deployment catalog-api -n fiapgames --patch-file k8s/patches/catalog-api-image-pull-policy.json
kubectl patch deployment payments-api -n fiapgames --patch-file k8s/patches/payments-api-image-pull-policy.json
kubectl patch deployment notifications-api -n fiapgames --patch-file k8s/patches/notifications-api-image-pull-policy.json

kubectl get pods -n fiapgames
```

```bash
# 8. sobe o API Gateway (Kong + Konga)
#
#    8a. a Secret com a config declarativa é GERADA a partir do arquivo canônico,
#        em vez de ser um manifesto próprio — assim o conteúdo do kong.yml nunca
#        fica duplicado em dois lugares. É idempotente, pode rodar quantas vezes quiser.
kubectl create secret generic kong-declarative-config -n fiapgames \
  --from-file=kong.yml=kong/kong.k8s.yml --dry-run=client -o yaml | kubectl apply -f -

#    8b. aplica os manifestos. Os prefixos numéricos garantem a ordem, já que
#        "kubectl apply -f" aplica em ordem alfabética:
#        00 ConfigMap de conexão -> 01 Job (migrations + seed) -> 02 Kong -> 03 Konga
kubectl apply -f k8s/kong/

#    8c. confere que o seed rodou (é ele que carrega rotas e políticas no banco)
kubectl wait --for=condition=complete job/kong-bootstrap -n fiapgames --timeout=180s
kubectl logs job/kong-bootstrap -n fiapgames
```

Pronto — o gateway está em `http://localhost:8000` e é por ali que tudo deve passar:

| Endereço | O que é |
|---|---|
| `http://localhost:8000` | **proxy** — a API inteira (`/api/users`, `/games`, `/orders`, `/library`, `/health`) |
| `http://localhost:8002` | Kong Manager (GUI oficial) |
| `http://localhost:1337` | Konga (GUI da comunidade) |
| `http://localhost:8001` | Admin API do Kong |
| `http://localhost:8100/metrics` | métricas Prometheus |

> Se o pod do `postgres-kong` reiniciar, o volume é `emptyDir` — schema e rotas vão embora junto. Para reconstruir: `kubectl delete job kong-bootstrap konga-prepare -n fiapgames` e repetir o passo 8.

**Passo 9 (opcional — bypass do gateway, só para debug).** Depois do passo 8 isto não é mais necessário: o front e os testes vão todos por `http://localhost:8000`. Serve só para bater direto num serviço, contornando o Kong e a validação de JWT — útil para isolar se um problema é do gateway ou da aplicação, e para acessar o `/swagger` do Catalog (que não é roteado pelo gateway, porque proteger asset estático com JWT impediria o browser de carregá-lo).

O `Service` do `user-api` é `ClusterIP` e o do `catalog-api` é `NodePort 30080` — mas o `kind-config.yaml` só publica as portas do gateway, então nenhum dos dois é alcançável do host sem port-forward. Isso é intencional: reforça que o Kong é a única porta de entrada. `Start-Process ... -WindowStyle Hidden` desacopla os processos do terminal que os iniciou (fechar o terminal não os mata — só reiniciar o PC/Docker Desktop, ou o pod correspondente reiniciar, derruba o forward):

```powershell
# 9. (opcional) acesso direto, sem gateway
Start-Process kubectl -ArgumentList 'port-forward -n fiapgames svc/catalog-api 8090:80' -WindowStyle Hidden
Start-Process kubectl -ArgumentList 'port-forward -n fiapgames svc/user-api 8091:80' -WindowStyle Hidden
Start-Process kubectl -ArgumentList 'port-forward -n fiapgames svc/mailhog 8025:8025' -WindowStyle Hidden
```

> O passo 7 (`imagePullPolicy: IfNotPresent`) só é necessário para teste local com Kind, porque as imagens não foram publicadas de verdade no Docker Hub ainda. Depois que as imagens forem publicadas (`docker push`) e os manifestos apontarem para um registry real, isso deixa de ser necessário — o comportamento padrão (`imagePullPolicy: Always` para tag `latest`) volta a ser o correto.

**Resultado esperado** — 12 pods `1/1 Running` + 3 Jobs `Completed`:

```
NAME                                 READY   STATUS      RESTARTS   AGE
catalog-api-xxxxxxxxxx-xxxxx         1/1     Running     0          5m
kong-xxxxxxxxxx-xxxxx                1/1     Running     0          2m
kong-bootstrap-xxxxx                 0/1     Completed   0          2m
konga-xxxxxxxxxx-xxxxx               1/1     Running     0          2m
konga-prepare-xxxxx                  0/1     Completed   0          2m
mailhog-xxxxxxxxxx-xxxxx             1/1     Running     0          10m
notifications-api-xxxxxxxxxx-xxxxx   1/1     Running     0          5m
payments-api-xxxxxxxxxx-xxxxx        1/1     Running     0          5m
postgres-xxxxxxxxxx-xxxxx            1/1     Running     0          10m
postgres-kong-xxxxxxxxxx-xxxxx       1/1     Running     0          10m
rabbitmq-xxxxxxxxxx-xxxxx            1/1     Running     0          10m
sqlserver-xxxxxxxxxx-xxxxx           1/1     Running     0          10m
sqlserver-users-xxxxxxxxxx-xxxxx     1/1     Running     0          10m
user-api-xxxxxxxxxx-xxxxx            1/1     Running     0          5m
user-api-migrate-xxxxx               0/1     Completed   0          5m
```

> É normal o pod do `kong` reiniciar uma ou duas vezes logo no início: o initContainer só espera a **porta** do Postgres, não as migrations. Se o Kong subir antes do `kong-bootstrap` terminar, ele sai com erro de schema e o Kubernetes o reinicia — resolve sozinho em segundos.

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

# só o gateway (útil para ver o access log do proxy e os 401 do plugin jwt)
stern -n fiapgames kong

# seguir uma requisição específica pelos 4 serviços, pelo header do correlation-id
stern -n fiapgames ".*" --include "<valor-do-X-Correlation-ID>"
```

### Testando os dois fluxos completos pelo gateway

Tudo entra por `http://localhost:8000` (Payments e Notifications não expõem Service HTTP — eles só reagem a eventos do RabbitMQ):

```bash
# 0. rota protegida SEM token -> 401 do Kong, não chega no Catalog
curl -i http://localhost:8000/games

# 1. cadastro (rota pública) -> UserCreatedEvent -> e-mail de boas-vindas
curl -X POST http://localhost:8000/api/users -H "Content-Type: application/json" \
  -d '{"nome":"Joao K8s","email":"joao.k8s@example.com","password":"SenhaForte@123"}'

# 2. login (rota pública) -> access token
TOKEN=$(curl -s -X POST http://localhost:8000/api/users/login -H "Content-Type: application/json" \
  -d '{"email":"joao.k8s@example.com","password":"SenhaForte@123"}' \
  | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p')

# 3. compra — agora COM token em todas as chamadas
curl -X POST http://localhost:8000/games -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title":"Dark Souls III","description":"Souls-like","price":39.90,"genre":"RPG"}'

curl -X POST http://localhost:8000/games/{gameId}/purchase -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"userId":"{userId}"}'

curl http://localhost:8000/orders/{orderId} -H "Authorization: Bearer $TOKEN"

# 4. biblioteca — Catalog busca nome/e-mail reais no Users via RabbitMQ dentro do cluster
curl http://localhost:8000/library/{userId} -H "Authorization: Bearer $TOKEN"
```

Validado de ponta a ponta dentro de um cluster Kind real: cadastro publicou `UserCreatedEvent` e o e-mail de boas-vindas chegou no Notifications; a compra foi `Approved` pelo Payments e a confirmação de compra também chegou por e-mail; e `GET /library/{userId}` retornou nome/e-mail reais do usuário (via `UserLookupRequested`/`Responded` no RabbitMQ) junto com o jogo comprado — tudo isso com os 4 microsserviços rodando como pods no mesmo cluster, sem nenhuma simulação manual de evento.

### Front-end contra o gateway

O [`FiapGames.Web`](../FiapGames.Web) já aponta para o gateway: as duas variáveis do `.env` (`VITE_API_BASE_URL` e `VITE_USERS_API_BASE_URL`) valem `http://localhost:8000`, e o `src/api/httpClient.ts` anexa `Authorization: Bearer` automaticamente em toda requisição a partir do `authStore`.

```bash
cd ../FiapGames.Web && npm run dev     # http://localhost:5173
```

Antes de logar, as telas do Catalog devem dar 401 (é o gateway barrando); depois do login, funcionam. O `HealthBadge` fica verde nos dois momentos, porque `/health` é rota pública. Quando o token expira (15 min), o `httpClient` limpa a sessão e a UI volta para o login — não há renovação automática de token implementada.

Encerrar o cluster:

```bash
kind delete cluster --name fiapgames
```
