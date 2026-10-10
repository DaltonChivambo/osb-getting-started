# Componentes, imagens, containers e ferramentas — o mapa completo

Este documento responde a "o que é cada coisa neste ambiente, de onde vem, e como se ligam
umas às outras". É o mapa de tudo o que é descarregado, construído, corrido e usado.

- Para **o que fazer e por que ordem** (logins, licenças, pulls): `LOGIN-ORACLE.md`.
- Para **como o OSB funciona por dentro** (Proxy → Pipeline → Business Service): `CONCEITOS.md`.
- Para **ligar/desligar no dia-a-dia**: `RUNNING.md`.

## 1. A ideia numa imagem

O ambiente tem **duas fases** bem separadas. Confundi-las é a causa mais comum de erros.

```
 FASE 1 — PREPARAR (uma vez, manual, demora horas)          FASE 2 — CORRER (todos os dias)
 ─────────────────────────────────────────────────          ───────────────────────────────

 container-registry.oracle.com                               ./start-osb.sh
   ├─ database/enterprise:12.2.0.1 ──pull+tag──┐                  │
   └─ middleware/fmw-infrastructure:12.2.1.4 ──┤                  ▼
                                               │            soadb ──► osbas ──► osbms
 edelivery.oracle.com                          │            (BD)    (Admin)  (Managed)
   ├─ fmw_12.2.1.4.0_soa.jar ──┐               │              ▲         │        │
   ├─ fmw_12.2.1.4.0_osb.jar ──┼─ buildDocker  │              └─────────┴────────┘
   └─ fmw_12.2.1.4.0_b2b...jar ┘  Image.sh ────┤              (usam as imagens da fase 1)
                                               ▼
                              imagens locais: oracle/database, oracle/soasuite
```

- **Fase 1** produz **imagens** (os "moldes"). Só se repete se apagares as imagens.
- **Fase 2** cria **containers** a partir dessas imagens. É o que `./start-osb.sh` faz, e
  **assume que a fase 1 está completa** — por isso, sem imagens, falha logo no primeiro passo.

## 2. Vocabulário Docker em 30 segundos

| Termo | O que é | Analogia |
|---|---|---|
| **Imagem** | Pacote só de leitura com um sistema + programas já instalados | Um molde / um `.iso` |
| **Container** | Uma imagem **em execução**. Podes ter vários da mesma imagem | Uma instância ligada |
| **Volume / bind mount** | Pasta que sobrevive ao container (os dados não se perdem ao apagá-lo) | Disco externo |
| **Rede do compose** | Rede privada onde os containers se encontram pelo **nome** (`soadb`, `osbas`) | LAN interna |
| **Porta publicada** | `7001:7001` = porta 7001 do teu PC → porta 7001 do container | Redirecionamento de porta |
| **Registry** | Servidor de imagens (`container-registry.oracle.com`, Docker Hub…) | Loja de apps |

## 3. As imagens (3)

| # | Imagem (nome final) | Origem | O que contém | Corre como container? |
|---|---|---|---|---|
| 1 | `localhost/oracle/database:12.2.0.1-ee` | `pull` de `database/enterprise:12.2.0.1` + `docker tag` | Oracle Database 12.2 Enterprise Edition pronto a usar | **Sim** → `soadb` |
| 2 | `fmw-infrastructure:12.2.1.4` | `pull` de `middleware/fmw-infrastructure:12.2.1.4` | Oracle Linux + **JDK 8** + **WebLogic Server** + bibliotecas comuns do Fusion Middleware (JRF) | **Não** — é só matéria-prima do build |
| 3 | `oracle/soasuite:12.2.1.4` | **construída por ti** com `buildDockerImage.sh` | A imagem 2 + SOA Suite + OSB + B2B/Healthcare instalados | **Sim** → `osbas` e `osbms` |

### Porque a imagem 1 leva um `docker tag`

O `docker-compose.yml` pede `${DC_REGISTRY_DB}/oracle/database:12.2.0.1-ee` e o `setenv.sh`
define `DC_REGISTRY_DB="localhost"`. O nome real no registry é outro, por isso dás-lhe um nome
extra (uma tag adicional; não duplica nada em disco). Se esta tag não existir, o Docker tenta
descarregar de um registry chamado `localhost` e dá `i/o timeout`.

### Como a imagem 3 é construída

```
fmw-infrastructure:12.2.1.4        ← imagem 2 (base: Linux + JDK 8 + WebLogic)
        │
        │  buildDockerImage.sh -v 12.2.1.4   (repositório oracle/docker-images)
        │  + os 3 jars colocados em OracleSOASuite/dockerfiles/12.2.1.4/
        ▼
oracle/soasuite:12.2.1.4           ← imagem 3
```

| Jar | Conteúdo | Obrigatório? |
|---|---|---|
| `fmw_12.2.1.4.0_soa.jar` | SOA Suite: BPEL, Mediator, Human Workflow, Business Rules. O OSB partilha infraestrutura (JRF, MDS) com ele | **Sim**, mesmo num domínio só-OSB |
| `fmw_12.2.1.4.0_osb.jar` | **Oracle Service Bus**: consola, motor de pipelines, transports REST/SOAP/JMS/FTP/Email | **Sim** — é o produto que usamos |
| `fmw_12.2.1.4.0_b2bhealthcare.jar` | B2B (EDI/AS2) e Healthcare (HL7) | O script de build espera-o; **não é usado** nos exercícios |

## 4. Os containers (3)

Definidos em `docker/docker-compose.yml`.

| Container | Imagem | Portas (PC → container) | Papel |
|---|---|---|---|
| `soadb` | 1 (`oracle/database`) | `1521` (SQL*Net), `5500` (EM Express) | Base de dados. Guarda as **schemas RCU**: configuração, segurança (OPSS), auditoria, metadata (MDS) |
| `osbas` | 3 (`oracle/soasuite`) | `7001` | **Admin Server** do WebLogic. Consolas `/console` e `/servicebus`. Na 1.ª vez corre o RCU e cria o domínio |
| `osbms` | 3 (`oracle/soasuite`) | `9001` (HTTP), `9002` (HTTPS) | **Managed Server** `osb_server1`. É aqui que as Proxy Services realmente atendem pedidos |

Notas importantes:

- `osbas` e `osbms` usam **a mesma imagem**. O que os distingue é o comando de arranque
  (`createDomainAndStart.sh` vs `startMS.sh`) e as variáveis de ambiente.
- **Quem faz o quê**: crias e configuras no `osbas` (:7001); o tráfego real entra pelo
  `osbms` (:9001). O `osbms` ainda assim depende do `osbas`: lê dele a configuração.
- `osb_server2` aparece `SHUTDOWN` na consola — é normal, este compose só cria container para
  o `osb_server1`.

### Quem depende de quem

```
soadb  ◄──── osbas  ◄──── osbms
 (BD)       (Admin)      (Managed)
```

`depends_on` só garante a **ordem de criação**, não que o anterior já esteja pronto. É por isso
que o `start-osb.sh` espera ativamente por cada um (healthcheck da BD; `RUNNING mode` no log do
servidor) antes de avançar.

## 5. Onde ficam os dados (volumes)

| O quê | Onde (no teu PC / Docker) | Montado em | Sobrevive a `down`? | Sobrevive a `down -v`? |
|---|---|---|---|---|
| Datafiles reais da BD | volume nomeado `osb_soadb_orcl` | `soadb:/ORCL` | Sim | **Não** |
| Pasta da BD (fica vazia) | `$DC_USERHOME/dbdata` | `soadb:/opt/oracle/oradata` | Sim | Sim |
| Domínio WebLogic/OSB (config, logs, o fix do `adapters.os_xml`) | `$DC_USERHOME/osbdomain` | `osbas` e `osbms`: `/u01/oracle/user_projects` | Sim | Sim |

`DC_USERHOME` vale `${HOME}/osb-docker` (definido no `setenv.sh`).

Duas armadilhas decorrentes disto:

1. **`osbas` e `osbms` partilham a mesma pasta de domínio.** É por isso que ambos escrevem no
   mesmo `adapters.os_xml` e que o `fix-adapters.sh` é necessário (ver `RUNNING.md`).
2. **Os dados da BD vivem no volume nomeado**, não na pasta `dbdata`. Apagar só
   `$DC_USERHOME` não reinicia a BD; é preciso também `docker volume rm osb_soadb_orcl`.

## 6. Portas — resumo

| Porta | Serviço | Para quê | Exemplo |
|---|---|---|---|
| `1521` | `soadb` | Ligação SQL à base de dados | cliente SQL |
| `5500` | `soadb` | Enterprise Manager Express | browser |
| `7001` | `osbas` | **Admin Console** e **Service Bus Console** | `http://localhost:7001/console`, `/servicebus` |
| `9001` | `osbms` | Proxy Services (HTTP) | `http://localhost:9001/echotest` |
| `9002` | `osbms` | Proxy Services (HTTPS) | — |

## 7. O que acontece quando arrancas e quando chamas

### Arranque (`./start-osb.sh`)

```
1. soadb   sobe, espera pelo healthcheck ("DATABASE IS READY TO USE!")
2. fix-adapters.sh                      ← reduz o adapters.os_xml a 1 bloco <ldap>
3. osbas   sobe → RCU/domínio (só na 1.ª vez) → AdminServer a RUNNING
4. fix-adapters.sh                      ← o osbas acrescentou o bloco dele
5. osbms   sobe → liga-se ao osbas → osb_server1 a RUNNING
```

### Um pedido real

```
curl / Postman / aplicação
        │  HTTP :9001
        ▼
   osbms  (Proxy Service → Pipeline → Business Service)
        │
        ├─ consulta config/segurança ──► soadb (schemas RCU)
        │
        ▼
   backend externo (ex.: httpbin.org)
```

O percurso medido, linha a linha, está em `FLUXO.md`.

## 8. Todas as ferramentas

### 8.1 No teu computador (Windows)

| Ferramenta | Para quê | Obrigatória? |
|---|---|---|
| **Docker Desktop** (backend WSL2) | Corre as imagens/containers | **Sim** |
| **Docker Compose** (`docker-compose`) | Sobe os 3 containers a partir do `docker-compose.yml` | **Sim** (vem com o Docker Desktop) |
| **Git Bash** (ou WSL2) | Os scripts são `.sh`; não correm em PowerShell/CMD | **Sim** |
| **Git** | Clonar `oracle/docker-images` e este repositório | **Sim** |
| **Browser** | Consolas `:7001/console` e `:7001/servicebus` | **Sim** |
| **`curl`** | Testar Proxy Services (usado pelo `test-proxy.sh`) | **Sim** (vem com o Git Bash) |
| **Postman** | Alternativa gráfica ao `curl` (`test/osb-test.postman_collection.json`) | Opcional |
| **JDK 8 de 64 bits + JDeveloper 12.2.1.4** | IDE para desenvolver; instalado a partir do zip `V983382-01` | **Opcional** — a consola web chega para os exercícios |

> O Java do teu PC **não** é usado pelos containers: cada imagem traz o seu próprio JDK 8. O
> JDK 8 local só serve para instalar o JDeveloper.

### 8.2 Sites da Oracle

| Site | Para quê | Credencial |
|---|---|---|
| **edelivery.oracle.com** | Descarregar os jars (SOA, OSB, B2B) e o JDeveloper | Conta Oracle, no browser |
| **container-registry.oracle.com** | `docker pull` da BD e do `fmw-infrastructure` | `docker login` com **Auth Token** + licença por imagem |

Detalhe em `LOGIN-ORACLE.md`.

### 8.3 Scripts oficiais da Oracle (repositório `oracle/docker-images`)

| Script | Quando corre | O que faz |
|---|---|---|
| `buildDockerImage.sh` | Fase 1, uma vez, no teu PC | Constrói `oracle/soasuite:12.2.1.4` |
| `createDomainAndStart.sh` | Dentro do `osbas`, a cada arranque | 1.ª vez: RCU + cria o domínio + arranca o AdminServer. Depois: salta o RCU/domínio e arranca |
| `startMS.sh` | Dentro do `osbms` | Arranca o Managed Server contra o `osbas` |

### 8.4 Programas que correm dentro dos containers

| Componente | Em que container | O que é |
|---|---|---|
| **Oracle Database 12.2** | `soadb` | Base de dados relacional |
| **RCU** (Repository Creation Utility) | `osbas` (1.ª vez) | Cria as schemas (`OSB01_OPSS`, `OSB01_MDS`…) na BD |
| **WLST** (WebLogic Scripting Tool) | `osbas` (1.ª vez) | Gera a estrutura do domínio com os templates OSB |
| **WebLogic Server 12c** | `osbas`, `osbms` | O servidor de aplicações Java onde tudo corre |
| **Oracle Service Bus 12c** | `osbas`, `osbms` | O produto de mediação (Proxy/Pipeline/Business Service) |
| **Oracle ADF Faces** | `osbas` | Tecnologia da Service Bus Console |
| **OPSS / libOVD** | `osbas`, `osbms` | Segurança e identity store embutido (origem do `adapters.os_xml`) |
| **Oracle Coherence** | `osbas`, `osbms` | Cache distribuída; aparece nos logs de arranque |
| **JDK 8** | `osbas`, `osbms` | A JVM do WebLogic |

### 8.5 Ficheiros deste repositório

| Ficheiro | Para quê |
|---|---|
| `docker/setenv.sh` | Variáveis `DC_*`: passwords, portas, versões, pastas (`DC_USERHOME`) |
| `docker/docker-compose.yml` | Define os 3 containers, portas, volumes e variáveis |
| `docker/start-osb.sh` | Sobe tudo pela ordem certa, com o fix e esperas |
| `docker/fix-adapters.sh` | Corrige o bug do `adapters.os_xml` (`duplicate keys`) |
| `test/test-proxy.sh` | `curl` a uma Proxy Service em `localhost:9001` |
| `test/osb-test.postman_collection.json` | O mesmo teste no Postman |
| `test/httpbin.wadl` | WADL de exemplo usado no `TUTORIAL.md` |

### 8.6 Serviço externo

| Serviço | Para quê |
|---|---|
| **httpbin.org** | Backend público do exercício: devolve em JSON os detalhes do pedido que recebeu |

## 9. O que **não** precisas

- **`fmw-infrastructure` como container** — só é base do build.
- **B2B/Healthcare** — vai no build mas nenhum exercício o usa.
- **JDeveloper** — dispensável para o tutorial; só se quiseres o IDE.
- **`osb_server2`** — não tem container.
- **Hosts file** — os containers resolvem-se por nome na rede do compose.

## 10. Recursos de máquina

Segundo o `README.md`: **~16 GB de RAM livres** e **~40 GB de disco**. A BD Oracle e os dois
servidores WebLogic são pesados; em máquinas mais pequenas o arranque falha ou fica muito lento.

Tempos medidos com o domínio já criado: `osbas` ~8 min até `RUNNING`, `osbms` ~5 min; a 1.ª vez
(RCU + criação do domínio) demora 20-40 min.

## 11. Mapa da documentação

| Quero… | Ler |
|---|---|
| Fazer logins, aceitar licenças, puxar imagens | `LOGIN-ORACLE.md` |
| Entender as peças (este documento) | `COMPONENTES.md` |
| Montar tudo do zero | `../README.md` |
| Ligar/desligar e resolver problemas | `RUNNING.md` |
| Criar a primeira Proxy Service | `TUTORIAL.md` |
| Perceber Proxy → Pipeline → Business Service | `CONCEITOS.md` |
| Ver um pedido real hop a hop | `FLUXO.md` |
| Sessões, tipagem REST, clustering, segurança | `CONCEITOS-AVANCADOS.md` |
