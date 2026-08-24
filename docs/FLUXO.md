# O fluxo completo de um pedido, ponta a ponta

Este documento segue **um pedido real**, do terminal até ao backend e de volta, usando a saída
verdadeira do `test/test-proxy.sh` depois do exercício do `TUTORIAL.md` estar montado. Não é
teoria: cada afirmação aqui está provada por uma linha da resposta.

Se o `TUTORIAL.md` é o "como montar" e o `CONCEITOS.md` é o "porquê", isto é o **"o que
realmente acontece quando carregas Enter"**.

## O comando e a resposta

```console
$ ./test-proxy.sh /echotest
A chamar: http://localhost:9001/echotest
---
HTTP/1.1 200 OK
Date: Mon, 24 Aug 2026 22:25:27 GMT
Transfer-Encoding: chunked
Content-Type: application/json; charset=iso-8859-1

{
  "args": {},
  "headers": {
    "Accept": "application/xml",
    "Ecid-Context": "1.37b4ae7f-8ca4-4de2-b2e8-d4abb390829a-00000166;kXjE0dJNVNKJ4MJN4PLHVMLH3KNJIVLGs5CEt9FCo5DEm0",
    "Host": "httpbin.org",
    "User-Agent": "Jersey/2.22.4 (HttpUrlConnection 1.8.0_451)",
    "X-Amzn-Trace-Id": "Root=1-6a8cc4da-5ac218ef152328ba0b138205"
  },
  "origin": "216.234.211.54",
  "url": "https://httpbin.org/get"
}
```

O truque do `httpbin.org/get` é que ele **devolve em JSON o pedido que recebeu**. Ou seja, o
corpo da resposta acima é um espelho: mostra-nos exatamente o que chegou ao backend depois de
passar por toda a cadeia OSB. É isso que torna este teste tão informativo.

## O caminho completo

```
    Git Bash (curl)                                    [ máquina Windows ]
         │  GET http://localhost:9001/echotest
         │  Host: localhost:9001
         │  User-Agent: curl/8.x
         ▼
    Docker Desktop  ── port mapping 0.0.0.0:9001 → container:9001
         │
         ▼
┌────────────────────────────────────────────────────┐
│  container osbms  (WebLogic managed server         │
│                    osb_server1)                    │
│                                                    │
│   Listener HTTP :9001                              │
│         │                                          │
│         ▼                                          │
│   Transport HTTP do OSB                            │
│   — procura que Proxy Service tem o endpoint       │
│     URI /echotest registado                        │
│         │                                          │
│         ▼                                          │
│   ╔══════════════════════════════════╗             │
│   ║ EchoTestPS  (Proxy Service)      ║             │
│   ╚══════════════════════════════════╝             │
│         │  Target →                                │
│         ▼                                          │
│   ╔══════════════════════════════════╗             │
│   ║ EchoTestPS_Pipeline  (Pipeline)  ║             │
│   ║   └── RouteNode1                 ║             │
│   ║        └── ação Routing          ║             │
│   ╚══════════════════════════════════╝             │
│         │  Route to →                              │
│         ▼                                          │
│   ╔══════════════════════════════════╗             │
│   ║ HttpBinBS  (Business Service)    ║             │
│   ║   Base URI: https://httpbin.org  ║             │
│   ║   Resource: /get   Método: GET   ║             │
│   ╚══════════════════════════════════╝             │
│         │                                          │
│         │  NOVO pedido HTTP, feito pelo cliente    │
│         │  Jersey do OSB (não é o curl reenviado)  │
└─────────┼──────────────────────────────────────────┘
          │  GET https://httpbin.org/get
          │  Host: httpbin.org
          │  User-Agent: Jersey/2.22.4
          │  Ecid-Context: 1.37b4ae7f-...
          ▼
    Internet (TLS) ──────────────► httpbin.org
                                        │
          ◄─────────────────────────────┘
          JSON com o que ele recebeu
          │
          ▼  (sobe a mesma cadeia ao contrário:
          │   Business Service → Response Pipeline → Proxy)
          │
    curl imprime: HTTP/1.1 200 OK + o JSON
```

## O que cada linha da resposta prova

Esta é a parte que vale a pena ler com atenção — a resposta contém a impressão digital de todo
o percurso.

| Evidência na resposta | O que prova |
|---|---|
| `HTTP/1.1 200 OK` | A cadeia inteira funcionou. Nenhum salto partido. |
| Pedido feito a `localhost:9001` | O runtime vive no **Managed Server** (`osbms`), não no Admin Server. |
| `"url": "https://httpbin.org/get"` | A Business Service resolveu Base URI (`https://httpbin.org`) + Resource (`/get`) corretamente, e saiu por **HTTPS** — o TLS de saída do container funciona. |
| `"Host": "httpbin.org"` | O OSB **reescreveu** o header `Host`. O curl enviou `Host: localhost:9001`; o que chegou ao backend foi `httpbin.org`. |
| `"User-Agent": "Jersey/2.22.4 (HttpUrlConnection 1.8.0_451)"` | **A prova mais importante** — ver abaixo. |
| `"Ecid-Context": "1.37b4ae7f-..."` | O OSB injetou um **ECID** (Execution Context ID), o identificador de correlação do Oracle FMW. É a assinatura de que o pedido passou por middleware Oracle. |
| `"origin": "216.234.211.54"` | O IP público por onde o pedido saiu (NAT do Docker + a tua ligação). Confirma que saiu mesmo para a Internet. |
| `Transfer-Encoding: chunked` | O OSB devolveu a resposta em streaming, sem esperar por ter o corpo todo. |
| `1.8.0_451` no User-Agent | O JDK 8 dentro da imagem — o mesmo cuja versão está por trás do bug do `Malformed IPv6 address` (ver `RUNNING.md`). |

### O `User-Agent` é a prova de que isto é mediação, não um túnel

Repara: o backend viu `User-Agent: Jersey/2.22.4`, **não** o `curl/8.x` que enviámos.

Isto significa que o OSB **não reencaminhou o teu pedido**. O que fez foi:

1. Terminar a ligação TCP do curl e ler o pedido até ao fim
2. Processá-lo internamente (Proxy → Pipeline → Route)
3. **Construir um pedido HTTP completamente novo**, com o seu próprio cliente HTTP (Jersey, a
   implementação JAX-RS do WebLogic), a partir da definição da Business Service
4. Abrir uma ligação TLS nova para o httpbin.org e enviar esse pedido novo
5. Ler a resposta, processá-la no Response Pipeline, e escrever uma resposta nova para o curl

São **duas ligações HTTP independentes**, não uma só encaminhada. É exatamente isto que torna
possível tudo aquilo para que o OSB existe: mudar headers, transformar o corpo, trocar de
protocolo (REST→SOAP, HTTP→JMS), chamar vários backends, autenticar de forma diferente em cada
ponta. Nada disto seria possível num simples reencaminhamento.

O `Accept: application/xml` que o backend recebeu é outro sintoma disto — não foi o curl que o
pediu; veio da forma como o OSB construiu o pedido de saída a partir do WADL.

## Porquê `:9001` e não `:7001`

Esta é a confusão mais comum de quem começa:

| Porta | Container | Papel | Quando se usa |
|---|---|---|---|
| **7001** | `osbas` (Admin Server) | **Design time** — as consolas web onde crias e ativas recursos | No browser, a montar as coisas |
| **9001** / 9002 | `osbms` (Managed Server `osb_server1`) | **Runtime** — onde as Proxy Services atendem pedidos | Nos pedidos reais, curl/Postman/clientes |

**Crias no `:7001`, mas quem responde é o `:9001`.** Foi exatamente por isso que, enquanto o
`osbms` ainda estava a arrancar, a consola funcionava mas o "Launch Test Console" dava
*"Test Console service is not running"* — o design time estava de pé, o runtime não.

E é também por isso que o passo **Activate** no fim do tutorial não é opcional: enquanto as
mudanças estão só na sessão de edição do Admin Server, o Managed Server não sabe nada delas.
O `Activate` é o que distribui a configuração de `:7001` para `:9001`.

## Onde o pedido pode partir, e o que verias

| Sintoma | Onde parou | Causa típica |
|---|---|---|
| `Connection refused` em `:9001` | Não chegou ao OSB | `osbms` não está `RUNNING` (ver `RUNNING.md`, secção 2) |
| `404 Not Found` | Chegou ao OSB, mas nenhuma proxy responde nesse path | Path errado, ou faltou fazer **Activate** da sessão |
| `500` com `OSB-380000: Invalid HTTP method: null` | Proxy → Pipeline OK, morreu na Business Service | Business Service criada sem WADL (ver `TUTORIAL.md`, nota 1) |
| `500` com `OSB-398075` | Não chegou a correr | Proxy a invocar Business Service diretamente, sem Pipeline no meio (`TUTORIAL.md`, nota 2) |
| Resposta 200 mas sem sair para a Internet | Route não fez nada | A ação `Routing` não está num Route Node (`TUTORIAL.md`, nota 3) |

## Trocar o `httpbin.org` por um backend real

O `httpbin.org` não tem nada de especial — é só um alvo público que devolve o pedido em JSON,
o que o torna ideal para *ver* o que a cadeia fez. Para apontar isto a um sistema teu, muda
**só a Business Service**:

- **Base URI** → o host do teu backend (ex: `https://api.interna.empresa.mz`)
- **Resource** → o endpoint (ex: `/clientes`)
- **Método** → o verbo certo

A `EchoTestPS`, o `EchoTestPS_Pipeline` e o `RouteNode1` ficam iguais. E é esse precisamente o
ponto da arquitetura: **os teus clientes continuam a chamar `:9001/echotest` sem saber que o
backend mudou.** Podes trocar de fornecedor, de versão de API ou de protocolo do lado de lá,
e a porta de entrada mantém-se estável — o Pipeline é onde absorves a diferença.

## A seguir

- Mecanismos mais profundos (sessões, tipagem REST, anatomia do Message Flow, clustering,
  OPSS) — `CONCEITOS-AVANCADOS.md`
- Voltar a montar tudo do zero, ou perceber o porquê de cada camada — `TUTORIAL.md` e
  `CONCEITOS.md`
