# Tutorial: primeira Proxy Service (passo a passo detalhado)

Guia completo, testado do início ao fim na Service Bus Console, para criar o primeiro ciclo
**cliente → Proxy Service → Pipeline → Route → Business Service → resposta**, usando o
`httpbin.org/get` como backend de teste (ver ../README.md, secção "porquê httpbin.org", se
tiveres essa dúvida).

Pré-requisito: ambiente a correr (ver `RUNNING.md`) e login feito em
http://localhost:7001/servicebus (user `weblogic`, password de `DC_ADMIN_PWD`).

## Porque é preciso ler isto com atenção

Este exercício parece trivial ("criar um proxy que chama um backend"), mas a Service Bus
Console 12c tem várias armadilhas não óbvias que nos fizeram perder tempo a primeira vez.
As mais importantes, para já entenderes o *porquê* de alguns passos abaixo:

1. **REST "untyped" (sem WADL) não funciona para invocar um backend.** Criámos a Business
   Service sem WADL/Swagger (a opção mais simples do wizard) e o Route falhava sempre com
   `[OSB-380000] General runtime error: Invalid HTTP method: null` — mesmo testando a Business
   Service sozinha (fora do proxy), com **Launch Test Console**. A OSB, nesta versão, precisa
   de um WADL (mesmo que gerado pelo próprio wizard, sem ficheiro externo) para saber que
   método HTTP usar. **Por isso usamos sempre a opção "Typed REST from wizard (with WADL)"** ao
   criar Business Service e Proxy Service — nunca "Typed/Untyped REST" com os campos WADL/Swagger
   em branco.

2. **Uma Proxy Service REST tipada (com WADL) não pode invocar diretamente uma Business
   Service REST tipada, se as "formas" (path/método) não forem idênticas.** Ao tentar ligar a
   `EchoTestPS` (recurso `/`) diretamente à `HttpBinBS` (recurso `/get`), a consola recusa com
   `[OSB-398075] A Proxy service of type [NATIVE REST: WADL ...] may not invoke service
   BusinessService ... of type [NATIVE REST: WADL ...]`. A solução standard é sempre meter um
   **Pipeline** no meio — é o Pipeline que lida com a "tradução" entre formas diferentes, uma
   Proxy pode sempre invocar um Pipeline.

3. **Dentro de um Pipeline, a ação de "Routing" só existe num nó Route, não dentro de um Stage
   normal.** Se adicionares manualmente um "Stage" dentro do Request Pipeline de um
   `PipelinePairNode`, a lista de ações de Communication mostra só `Dynamic Publish / Publish /
   Publish Table / Routing Options / Service Callout / Transport Headers` — sem "Routing". A
   ação `Routing` (a que faz `Route to <Service>` e termina o pipeline) só aparece dentro de um
   **nó Route** dedicado (ex: `RouteNode1`), que normalmente já vem criado automaticamente
   quando referencias o WADL certo ao criar o Pipeline.

Com isto em mente, os passos:

## 1. Cria o projeto

Project Explorer → **Create → New → Project** → nome `TESTE_OSB`

## 2. Cria a Business Service (o backend)

- Dentro do projeto: **Create → Resource → Business Service**
- Escolhe **Typed REST from wizard (with WADL)**
- **Basic Info**:
  - Name: `HttpBinBS`
  - Description: opcional
  - Base URI: `https://httpbin.org`
  - Virtualize: deixa por defeito
- **Resources**:
  - URI: apaga o valor pré-preenchido (a base URI) e escreve só `get`
  - **Add Resource**
- **Methods**:
  - Ao lado de `/get`, **Add Method** → Verb **GET** → Name por defeito (`Method0`) → sem parâmetros → confirma
- **Create**

### Confirma que funciona, sozinha, antes de continuares

- Abre a `HttpBinBS` → botão **Launch Test Console** (separador General, ou no "Page level menu")
- Escolhe o método GET/`Method0` → executa
- Deves receber uma resposta real do `httpbin.org` (JSON com `args`, `headers`, `origin`, `url`)
  e, na Response Metadata, `http:http-response-code = 200`

Se em vez disso deres `Invalid HTTP method: null`, confirma que usaste "Typed REST from wizard
(with WADL)" e não "Typed/Untyped REST" com os campos WADL em branco.

## 3. Cria a Proxy Service (a porta de entrada)

- **Create → Resource → Proxy Service**
- **Typed REST from wizard (with WADL)**
- **Basic Info**:
  - Name: `EchoTestPS`
  - Base URI: `/echotest` (aqui é só um path relativo, formato `/servicename` — a proxy corre
    dentro do próprio OSB, não tem host/porta externos)
- **Resources**:
  - URI: apaga o valor pré-preenchido e escreve só `/` (barra simples — representa a raiz do
    Base URI que já definiste; se deixares o valor igual ao Base URI, dá erro "URI cannot be
    empty")
  - **Add Resource**
- **Methods**:
  - Ao lado de `/`, **Add Method** → **GET** → confirma
- **Create**

Neste ponto, o wizard vai pedir logo um **target resource** — **não escolhas a Business
Service aqui**. Vai dar erro `[OSB-398075]` (formas incompatíveis, ver nota 2 acima). Clica
**Cancel** nesse passo específico — a Proxy Service fica criada na mesma, só com uma ligação
por resolver (fica um "1 Error(s) Found" pendente, resolvemos a seguir).

## 4. Cria o Pipeline (a "cola" entre a proxy e o backend)

- **Create → Resource → Pipeline**
- Name: `EchoTestPS_Pipeline`
- **Service Type**: **REST Service**
- Se aparecer uma secção **"Expose as a Proxy Service"** com um nome tipo
  `EchoTestPS_Pipeline-proxy` — não faz mal se não conseguires desligar, cria-se uma proxy
  extra que fica por usar (podes apagá-la no fim; não interfere com o resto)
- **WADL Name**: escreve/procura `EchoTestPS` (a proxy que já criaste) e seleciona-a — isto faz
  o Pipeline herdar a mesma "forma" REST da proxy
- **Path**: deve preencher-se sozinho (`/`)
- **Transport**: fica bloqueado/herdado, é normal
- **Create**

## 5. Liga o Pipeline à Business Service

- Abre o Pipeline criado → **Edit Message Flow** (ou já abre direto em edição)
- Deve já existir um **`RouteNode1`** de raiz (criado automaticamente por teres referenciado o
  WADL da proxy) — usa esse. (Se em vez disso só vires um `PipelinePairNode1` com Request/Response
  Pipeline, não sigas por aí a adicionar Stages — volta ao nível de topo do fluxo, o `RouteNode1`
  deve estar lá; ver nota 3 acima sobre porquê.)
- Clica dentro do `RouteNode1` → **Add an Action → Communication → Routing**
- Clica no `<Service>` em "Route to `<Service>`" → escolhe **HttpBinBS**
- Se pedir o método/operação, escolhe o GET/`Method0`
- **Save**

## 6. Liga a Proxy Service ao Pipeline

- Abre a `EchoTestPS` (a proxy, não o pipeline) → separador **General**
- Campo **Target → Name**: apaga o que lá estiver, escreve `EchoTestPS_Pipeline` e confirma com
  **Tab** (o campo tem pesquisa/autocomplete associado — escrever só o texto sem confirmar via
  Tab ou o ícone de pesquisa dá erro "Resource path is not specified" ao gravar)
- **Save**

## 7. Ativa a sessão

Canto superior direito da consola: **Activate** → escreve uma descrição → **Submit**

Sem isto, nada do que fizeste está realmente a correr — fica tudo em rascunho de sessão.

## 8. Testa

```bash
cd test
./test-proxy.sh /echotest
```

Uma resposta HTTP 200 com JSON do `httpbin.org` confirma o ciclo completo:
**cliente → EchoTestPS → EchoTestPS_Pipeline → Route → HttpBinBS → httpbin.org → resposta**.

## Resumo da estrutura final

```
EchoTestPS (Proxy Service, /echotest, GET)
     │  Target →
     ▼
EchoTestPS_Pipeline (Pipeline)
     │  RouteNode1 → ação Routing →
     ▼
HttpBinBS (Business Service, https://httpbin.org/get, GET)
     │
     ▼
httpbin.org (backend real)
```

## Se quiseres repetir isto para outro backend

Troca só:
- O **Base URI** da Business Service (passo 2) para o teu backend real
- O **path do Resource** dessa Business Service para o endpoint que queres chamar
- Mantém a estrutura Proxy → Pipeline → Route → Business Service — é a forma robusta que
  evita o erro `OSB-398075`, mesmo que as formas REST sejam parecidas.
