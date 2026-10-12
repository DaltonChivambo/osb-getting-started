# Conceitos: como o OSB está montado e o que o teste prova

Este documento explica a arquitetura por trás do ambiente — o que cada peça é, como se
relacionam, e o que o exercício do `TUTORIAL.md` demonstra realmente. Pensado para quem quer
perceber o "porquê", não só o "como clicar".

## 1. WebLogic Server vs. Oracle Service Bus

É fácil confundir os dois, porque andam sempre juntos nestes ambientes — mas são coisas
diferentes, em camadas:

```
WebLogic Server          ← o motor genérico: arranca processos Java, gere deployments,
  │                          clustering, transações, consola de admin genérica, segurança...
  │                          (é comparável a Tomcat/JBoss, mas "enterprise" e da Oracle)
  │
  ├── Domínio WebLogic    ← uma instalação/configuração concreta (o nosso "infra_domain",
  │                          criado pelo RCU + createDomainAndStart.sh)
  │
  ├── AdminServer         ← um dos servidores do domínio (o nosso container `osbas`)
  │
  └── osb_server1         ← outro servidor do domínio (o nosso container `osbms`)
        │
        └── Oracle Service Bus  ← um PRODUTO instalado por cima do WebLogic, como um
                                    conjunto de aplicações Java: a Service Bus Console, o
                                    motor de pipelines, os transports REST/SOAP/JMS/FTP, etc.
```

**O WebLogic não sabe nada de "Proxy Service" ou "Business Service"** — isso são conceitos do
OSB. O WebLogic só fornece a infraestrutura onde o OSB corre como mais uma aplicação.

### RCU e `createDomainAndStart.sh` — o que criaram o domínio

**RCU** (**Repository Creation Utility**) é a ferramenta da Oracle que cria (ou apaga) as
**schemas** numa base de dados Oracle, necessárias para produtos FMW (WebLogic, SOA, OSB)
guardarem a sua configuração interna: segurança/políticas (`OPSS`), auditoria (`IAU`), metadata
store (`MDS`), tabelas de infraestrutura comum (`STB`), etc. É a ferramenta por trás daquelas
linhas nos logs do `osbas`:

```
Repository Creation Utility - Checking Prerequisites
Creating Common Infrastructure Services(STB)
Creating Audit Services Append(IAU_APPEND)
Creating Metadata Services(MDS)
...
```

Cada schema fica prefixada com o `RCUPREFIX` do `setenv.sh` (`OSB01`) — daí nomes como
`OSB01_OPSS`. **Não é a tua base de dados de negócio** — é infraestrutura interna que o próprio
WebLogic/OSB precisa para funcionar. (Foi exatamente isto que ficou em falta quando o volume
`/ORCL` da `soadb` foi substituído por um novo, vazio, num `docker-compose down`+`up` sem o
volume nomeado — as schemas RCU deixaram de existir, e o `osbas` falhou com `ORA-01017:
invalid username/password`, que na realidade queria dizer "esta schema já não existe".)

**`createDomainAndStart.sh`** é o script (do repositório oficial `oracle/docker-images`) que
corre dentro do container `osbas` como o seu comando principal. Faz, por ordem, na primeira vez:

1. **Corre o RCU** — cria as schemas na `soadb` (ou apaga+recria, se detetar que já existiam mas
   incompletas — foi o que aconteceu ao resumir o `osbas` depois de uma interrupção a meio)
2. **Cria o domínio WebLogic/OSB** — via WLST, gera a estrutura de ficheiros do domínio
   (`infra_domain`) com os templates OSB
3. **Arranca o AdminServer**

Nas vezes seguintes é **idempotente**: verifica ficheiros-marcador (`RCU.OSB01.suc` e
`SOA.DOMAINCFG.suc`, dentro de `/u01/oracle/user_projects/container/infra_domain/`) e, se já
existirem, salta os passos 1 e 2, indo direto para o 3 — é por isso que se vê
`"SOA RCU has already been loaded. Skipping..."` e `"Domain Already configured. Skipping..."`
nos arranques seguintes (ver `../README.md`, secção 4.2).

## 2. Os três containers e os seus papéis

| Container | O que é | Para que serve |
|---|---|---|
| `soadb` | Oracle Database | Guarda as **schemas RCU** — tabelas internas que o WebLogic/OSB precisam para configuração, segurança, auditoria. Não é "a tua" base de dados de negócio. |
| `osbas` | WebLogic **Admin**Server | O "painel de controlo": consolas web de administração (`:7001/console` e `:7001/servicebus`). Também é quem, na primeira vez, corre o RCU e cria o domínio. |
| `osbms` | WebLogic **Managed** Server (`osb_server1`) | Onde as Proxy Services **realmente correm** e atendem pedidos (`:9001`/`:9002`). |

Regra de bolso: **crias na consola do `osbas`, mas quem atende pedidos reais é o `osbms`**, e
ambos dependem do `soadb` por baixo.

## 3. De onde vem a interface web

- **`:7001/console`** (Admin Console) — vem **sempre com o WebLogic**, genérica, para geres
  qualquer domínio (servidores, datasources, deployments). Nada específico de OSB. Tecnologia
  mais antiga (Struts).
- **`:7001/servicebus`** (Service Bus Console) — faz parte do **produto OSB**, instalada por
  cima do WebLogic. É onde criámos a Business Service e a Proxy Service. Construída com
  **Oracle ADF Faces** — é por isso que os bugs de login que apanhámos (o `Malformed IPv6
  address`, ver `RUNNING.md`) afetam esta consola e não o `console` genérico.

Ambas são apps Java normais (`.war`/`.ear`) **deployadas no `osbas`** — por isso só existem em
`:7001`, nunca em `:9001`/`:9002` (esses são só tráfego runtime, sem interface).

## 4. O padrão de mediação: Proxy → Pipeline → Business Service

Este é o conceito central do OSB, e o que o exercício do `TUTORIAL.md` prova que funciona:

```
Cliente (curl/Postman)
    │  GET /echotest
    ▼
Proxy Service (EchoTestPS)      ← porta de entrada pública, em :9001
    │
    ▼
Pipeline (EchoTestPS_Pipeline)  ← lógica de processamento/routing
    │  ação Route
    ▼
Business Service (HttpBinBS)    ← definição do backend real
    │  GET https://httpbin.org/get
    ▼
httpbin.org                     ← serviço externo real
```

### Porque três camadas, e não uma só?

- **Proxy Service** — o que o mundo exterior vê e chama. Desacoplada do backend: podes mudar
  o backend sem os clientes da proxy saberem.
- **Business Service** — a definição de "onde o pedido vai realmente parar" (host, path,
  método). Desacoplada da proxy: a mesma Business Service pode ser chamada por várias proxies
  diferentes.
- **Pipeline** — a "cola" no meio, onde vive a lógica: routing, transformação de
  request/response, validação, tratamento de erros, chamadas a múltiplos backends, etc. É
  também a camada que resolve incompatibilidades entre a "forma" da proxy e a "forma" do
  backend (ver `TUTORIAL.md`, nota 2 — uma proxy REST tipada não pode invocar diretamente uma
  Business Service REST tipada se as formas não bateram certo; o Pipeline resolve isso).

Numa integração real, isto é o que te permite, por exemplo: expor uma Proxy Service estável
para os teus clientes, enquanto trocas o backend por trás (nova versão da API, novo
fornecedor, etc.) sem ninguém do lado de fora notar — o Pipeline é onde adaptas as diferenças.

### O que o teste concreto prova

O `httpbin.org` não tem nada de especial — é só um alvo público e conveniente (devolve em JSON
os detalhes do pedido que recebeu, ótimo para confirmar visualmente que o pedido chegou lá).
O que o teste realmente confirma é que o **mecanismo de mediação está vivo, de ponta a ponta,
neste ambiente Docker**:

1. A Proxy Service recebe um pedido HTTP externo
2. O Pipeline processa-o (aqui, só um Route — mas é o mesmo sítio onde metes lógica mais
   complexa depois)
3. A Business Service encaminha para um backend real
4. A resposta volta, sem nenhum passo partido no meio

Troca o `httpbin.org` por um sistema teu, e a arquitetura (proxy/pipeline/routing) é
exatamente a mesma. Este exercício é a base sobre a qual constróis qualquer integração real a
seguir.

## 5. Application Servers e o JDeveloper: quem desenha, quem executa

### O que é um Application Server

Um **Application Server** é um programa que **corre aplicações**: hospeda-as, executa-as e
expõe-nas na rede. Não é o IDE nem a base de dados: é o ambiente onde o teu projeto vive
**depois** de pronto.

```
Tu escreves o projeto  ──►  publicas (deploy)  ──►  o servidor executa e responde a pedidos
   (JDeveloper)                                       (WebLogic = Application Server)
```

O JDeveloper só **desenha e empacota**. Quem **executa** é o application server.

### Neste ambiente

- O application server é o **Oracle WebLogic Server** (ver secção 1). O OSB é uma aplicação que
  corre dentro dele.
- No Docker, são os contentores `osbas` (Admin Server, `:7001`) e `osbms` (managed server
  `osb_server1`, `:9001`).
- O **Admin Server** administra o domínio e recebe os *deploys*; o **managed server** é onde as
  Proxy Services respondem a pedidos.

### Design-time vs. runtime

O JDeveloper (Quick Start) e o contentor Docker trazem, cada um, o seu OSB 12.2.1.4, mas com
papéis diferentes:

| | **Design-time** | **Runtime** |
|---|---|---|
| Onde | JDeveloper, `C:\Oracle\Middleware\Oracle_Home\osb` | Contentores `osbas` / `osbms` |
| Para quê | Desenhar e validar Proxy, Pipeline e Business Service | Executar e responder a pedidos |
| Resultado | Ficheiros de projeto | Serviços ativos em `:9001` |
| Exige servidor | Não | É o servidor |

Os dois têm de ser da **mesma versão** (12.2.1.4) para a publicação ser compatível.

### De onde vem o OSB do Docker

Não é uma imagem descarregada já pronta: foi **construída localmente**.

| Container | Imagem | Origem |
|---|---|---|
| `osbas`, `osbms` | `localhost/oracle/soasuite:12.2.1.4` | `buildDockerImage.sh` do repositório `oracle/docker-images` (`OracleSOASuite`), com a base `middleware/fmw-infrastructure:12.2.1.4` do Oracle Container Registry e os jars `fmw_12.2.1.4.0_soa.jar`, `..._osb.jar` e `..._b2bhealthcare.jar` do eDelivery |
| `soadb` | `localhost/oracle/database:12.2.0.1-ee` | `database/enterprise:12.2.0.1` do Oracle Container Registry, com tag `localhost/...` |

O domínio `infra_domain` **não vem na imagem**: é criado no primeiro arranque do `osbas`
(secção 1). Passos e logins em `../README.md` e `LOGIN-ORACLE.md`.

### A janela "Application Servers" do JDeveloper

*Window → Application Servers* é só a lista das **ligações** a servidores onde se pode publicar.
Uma ligação (por exemplo `osb-docker`) **não instala nada**: guarda host, porta, utilizador,
password e o nome do domínio.

| Tipo de servidor | Exemplo |
|---|---|
| **Externo** | `osb-docker`, que aponta para `localhost:7001` (porta mapeada do contentor `osbas`) |
| **Integrado** | *IntegratedWebLogicServer*, que o próprio JDeveloper arranca (Derby embutida) |

```
JDeveloper (Windows)  ──  ligação "osb-docker"  ──►  localhost:7001  ──►  contentor osbas
   desenha o projeto       (host + porta + login)     (porta mapeada)      (OSB 12.2.1.4)
```

A ligação fica guardada no perfil do utilizador (`%APPDATA%\JDeveloper\system...\`), não no
Oracle Home: apagar essa pasta apaga a ligação. Como criá-la e testá-la, passo a passo, está em
`JDEVELOPER.md`.

### Analogia

- JDeveloper = o **editor**.
- Application server = o **servidor onde o serviço realmente funciona**.
- Ligação = o **endereço** que diz ao editor para onde enviar o trabalho.

Sem servidor a correr, o projeto são só ficheiros: não há nada a responder a pedidos.

## A seguir

Para a instalação do IDE e como publicar a partir dele, ver **`JDEVELOPER.md`**.

Para mecanismos mais profundos — o modelo de sessões da consola, porque a tipagem REST importa
tecnicamente, a anatomia completa de um Message Flow (Stage vs Route Node), clustering, e
segurança (OPSS) — ver **`CONCEITOS-AVANCADOS.md`**.
