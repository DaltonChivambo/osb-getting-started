# Conceitos avançados

Continuação do `CONCEITOS.md` — para quem já fez o `TUTORIAL.md` e quer perceber mecanismos
mais profundos da plataforma: sessões de edição, tipagem REST, a anatomia real de um pipeline,
clustering, e segurança. Assume que já leste `CONCEITOS.md`.

## 1. O modelo de sessões da consola

Reparaste que, ao editar recursos na Service Bus Console, nada fica "a sério" até clicares
**Activate**? Isto não é um detalhe de UI — é o modelo de concorrência da consola:

- Ao começares a editar (a partir do momento em que clicas **Create** ou abres algo em modo de
  edição), a consola abre uma **sessão** associada ao teu utilizador (`weblogic Session` — viste
  isto no canto superior direito, com **Activate / Discard / Exit**).
- Todas as mudanças que fazes (criar/editar/apagar recursos) ficam **isoladas nessa sessão** —
  uma cópia de rascunho da configuração do domínio, não a configuração "live".
- **Activate** aplica atomicamente todas as mudanças da sessão à configuração real (e distribui
  para todos os managed servers do cluster que a usem — no nosso caso, só o `osb_server1`).
- **Discard** deita fora a sessão inteira, sem tocar na configuração real.

Isto existe para permitir que várias pessoas editem o mesmo domínio ao mesmo tempo sem se
pisarem, e para garantir que uma mudança a meio (ex: criaste a Proxy mas ainda não ligaste o
Pipeline) nunca fica visível/ativa por acidente. É também porque, ao longo do `TUTORIAL.md`,
íamos vendo erros de validação (`1 Error(s) Found`) sem que isso rebentasse nada em produção —
os erros ficam contidos na sessão até resolveres e ativares.

## 2. Porque é que "untyped REST" não funciona, na prática

No `TUTORIAL.md` vimos que uma Business Service REST sem WADL falha com
`Invalid HTTP method: null`. A razão técnica: o transporte REST da OSB tem dois modos de
invocação bem diferentes:

- **Native REST** (o que usámos, via "Typed REST from wizard (with WADL)") — a OSB sabe, a
  partir do WADL, exatamente que **recursos** (paths) e **métodos** (verbos HTTP) o serviço
  suporta. Uma invocação native REST é otimizada: o corpo da mensagem passa quase
  "as-is" entre proxy e backend, sem conversão para o modelo de mensagem XML interno genérico
  da OSB. Para isso funcionar, a OSB precisa de saber, em *design time*, qual vai ser o método
  HTTP de cada operação — daí precisar do WADL.
- **"Any REST" / untyped** — sem WADL, a OSB não tem essa informação de design time. Nalgumas
  versões/combinações isto funciona como passthrough genérico (herda o método do pedido
  recebido); nesta versão (12.2.1.4, JDK 8u451), na prática, falha a resolver o método na
  invocação de saída — daí o `null`.

É também esta mesma exigência de "forma conhecida" que está por trás do erro
`[OSB-398075]` (uma Proxy nativa REST não pode invocar diretamente uma Business Service nativa
REST se as formas não baterem certo) — a otimização de invocação direta só é segura quando a
OSB tem a certeza, à partida, de que as duas pontas falam exatamente a mesma "linguagem"
(mesmo path, mesmo método). Um Pipeline no meio abdica dessa otimização a troco de
flexibilidade — é sempre permitido, porque entra na via genérica (mensagem XML interna), que
sabe adaptar-se a formas diferentes.

## 3. Anatomia real de um Message Flow

O que vimos no `TUTORIAL.md`, mas vale a pena consolidar como mapa mental:

```
Proxy Service
  │
  ▼
Message Flow                       ← o "programa" que processa o pedido
  │
  ├── Pipeline Pair Node            ← par de pipelines (Request + Response)
  │     ├── Request Pipeline
  │     │     └── Stage             ← contentor de ações não-terminais
  │     │           ├── Validate
  │     │           ├── Replace / Insert / Delete
  │     │           ├── Assign
  │     │           ├── Publish / Service Callout   ← chamadas que NÃO terminam o fluxo
  │     │           └── ...
  │     └── Response Pipeline       ← processa a resposta, no caminho de volta
  │
  └── Route Node                    ← nó SEPARADO, fora de qualquer Pipeline Pair
        └── ação Routing            ← "Route to <Service>", TERMINA o processamento
                                       do pedido e invoca o destino
```

A distinção chave (a que nos confundiu no `TUTORIAL.md`): **um Stage nunca tem a ação
"Routing"** — só tem ações de enriquecimento/validação/chamadas auxiliares. A ação que
realmente encaminha o pedido para um destino final só existe num **Route Node**, que é
estruturalmente diferente de um Pipeline Pair. Por isso, um fluxo típico tem tipicamente um (ou
mais) Pipeline Pair para lógica, seguido de um Route Node para o destino final.

Outras peças que não usámos, mas que existem no mesmo modelo:
- **Split-Join** — para paralelizar chamadas a múltiplos serviços e agregar respostas
- **Error Handlers** — a nível de Stage, Pipeline, ou do fluxo inteiro, para tratar falhas sem
  deixar o pedido cair num erro genérico 500

## 4. Clustering: porque existe `osb_server2` (mesmo sem container)

Reparaste, na Admin Console (*Environment → Servers*), que aparece sempre um `osb_server2`
`SHUTDOWN` / `Not reachable`. Isto não é um erro do nosso setup — é o **template de domínio OSB
da Oracle**, que por defeito cria sempre um cluster de 2 managed servers
(`osb_cluster` = `osb_server1` + `osb_server2`), pensado para produção com alta disponibilidade.
O nosso `docker-compose.yml` só cria container para `osb_server1` (o `osbms`) — o
`osb_server2` existe só como configuração de domínio, nunca correu.

Isto explica também os avisos periódicos que víamos nos logs do `osbas`, tipo:

```
OSB-473003: Aggregation Server Not Available. Failed to get remote aggregator
java.rmi.UnknownHostException: Could not discover administration URL for server 'osb_server2'
```

É o **Oracle Coherence** (visível nos logs como `Oracle Coherence GE 12.2.1.4.0`) — a
tecnologia de cache/dados distribuídos que a OSB usa para partilhar estatísticas e estado entre
os membros do cluster. Como só há um membro real (`osb_server1`), tenta periodicamente falar
com o `osb_server2` que não existe, e falha — de forma inofensiva, é só ruído de um cluster
"incompleto" por design (neste ambiente de aprendizagem, de propósito).

## 5. Segurança: OPSS e as políticas por defeito

Reparaste nestas linhas no arranque do `osbms`?

```
OSB-387098: Deployed new out-of-the-box Oracle Service Bus access control policy;
authorization provider: "XACMLAuthorizer", resource-id: "type=<jms>, ...",
policy: "Rol(ALSBSystem) | Rol(Admin)"
```

Isto é o **OPSS** (Oracle Platform Security Services) — o subsistema de segurança comum a
todos os produtos FMW — a instalar as políticas de autorização por defeito para os recursos
internos da OSB (filas JMS usadas pelos transports FTP/Email/SFTP, reporting, etc.), usando
**XACML** (uma linguagem standard para políticas de controlo de acesso) como motor de decisão.
`ALSBSystem` e `Admin` são papéis internos da OSB — só contas com esses papéis podem tocar
nesses recursos de infraestrutura. É também o OPSS que gere o **identity store** (o `libOVD`
que apanhámos no bug do `Malformed IPv6 address`, documentado em `RUNNING.md`) — a camada que
resolve "quem és tu e que papéis tens" sempre que fazes login ou que um recurso protegido é
acedido.

Não precisas de mexer nisto para o exercício do `TUTORIAL.md` — mas é o mecanismo por trás de
"porque é que só o `weblogic` consegue entrar na consola", e por trás de qualquer política de
segurança mais fina que venhas a definir numa Proxy Service real.
