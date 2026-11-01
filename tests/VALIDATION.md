# Reaplicação das rotas do Kong

Data: 01/11/2026.

## Falha observada na AWS

Após o deploy, o gateway público respondeu:

| Requisição | Resposta |
|---|---|
| `GET /health` | 200, `Healthy` |
| `GET /health/ready` | 200, `Ready` |
| `GET /search?q=minecrfat`, sem JWT | 404 do Kong, `no Route matched with those values` |

A configuração em `main` já continha `/search`. O bootstrap atualizava a Secret e reaplicava o Job `kong-bootstrap`, mas um Job concluído não executa novamente apenas porque a Secret mudou. O restart do gateway renovava o cache sem carregar a nova configuração no banco.

## Correção

AWS e Kind agora usam `ci/bootstrap-kong.sh`: atualizar Secret, recriar somente o Job de importação, aguardar conclusão e reiniciar o Kong. Não há exclusão do Postgres nem de dados das aplicações. Uma falha na importação interrompe o fluxo antes do restart.

## Validação executada

`node tests/kong-bootstrap.integration.mjs`, com Kubernetes Docker Desktop 1.34.1, Kong 3.9 e Postgres 11.16 reais, em namespace temporário:

1. Configuração inicial sem busca: `/search` responde 404.
2. Atualizar a Secret e reaplicar o Job concluído mantém o mesmo UID do Job e nenhuma rota de busca no banco, reproduzindo a falha.
3. O helper de produção recria o Job, cadastra uma rota `catalog-search` e faz `/search` responder 401 sem JWT; o Pod do Postgres mantém o mesmo UID.
4. Executar o bootstrap novamente preserva as rotas existentes e uma única rota de busca; `/search` continua respondendo 401.

Os quatro cenários passaram. A sintaxe dos três scripts Bash alterados e `git diff --check` também passaram. O teste só aceita contextos Docker Desktop/Kind e remove seu namespace ao terminar.

## Aplicação na AWS

A correção precisa ser publicada na branch usada pelo workflow de Orchestration. Depois, executar `deploy-prod` com ação `ligar` para reimportar a configuração no ambiente existente. O resultado esperado é `/search` responder 401 sem JWT e permitir a busca com JWT válido. A consulta autenticada e a sincronização de jogos na AWS continuam pendentes até essa aplicação.
