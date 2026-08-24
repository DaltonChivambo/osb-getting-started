# Como correr o ambiente OSB (dia-a-dia)

Este guia assume que já fizeste a configuração inicial (build da imagem `oracle/soasuite`,
`docker-images` clonado, domínio já criado pelo menos uma vez — ver `../README.md` para isso).
Aqui é só o essencial para ligar/desligar o ambiente numa sessão normal de trabalho.

## 0. Pré-requisitos

Docker Desktop tem de estar a correr. Se não estiver:

```bash
"/c/Users/<o teu user>/AppData/Local/Programs/DockerDesktop/Docker Desktop.exe" &
```

Espera até `docker info` funcionar sem erro antes de continuares.

**Importante — usa Git Bash, não PowerShell/CMD.** Todos os comandos abaixo (`source
./setenv.sh` incluído) são bash/POSIX. Em PowerShell, `source` não existe e o script nem chega
a correr — as variáveis `DC_*` ficam todas por definir, o `docker-compose` recebe valores em
branco, e vais ver avisos tipo `The "DC_ORCL_HOST" variable is not set` seguidos de erros como
`invalid spec: :/opt/oracle/oradata: empty section between colons`. Se vires esses avisos, é
sinal de que estás na shell errada.

Duas formas de resolver:

- **Abrir uma janela Git Bash a sério** — menu Iniciar → escreve "Git Bash" → Enter. O prompt
  passa a ser do estilo `user@host MINGW64 ~/caminho$`, não `PS C:\...>`. É preciso ser mesmo
  essa janela nova — correr `bash.exe` dentro do PowerShell sem mais nada normalmente só entra
  num sub-shell interativo, o que confunde fácil.
- **Ficar no PowerShell mas invocar o Git Bash só para o comando** — mais à prova de erro,
  porque não depende de "estares na janela certa". Usa `bash.exe -lc "..."` com o comando
  completo lá dentro:

  ```powershell
  & "C:\Program Files\Git\bin\bash.exe" -lc "cd '/d/caminho/para/o/repo/docker' && source ./setenv.sh && docker-compose up -d soadb"
  ```

  (ajusta o caminho ao teu clone; usa `/d/...` em vez de `D:\...`, com `/` em vez de `\`).

## 1. Subir o ambiente

Corre a partir da pasta `docker/` deste repositório (os container names — `soadb`, `osbas`,
`osbms` — já resolvem-se por DNS interno do Docker Compose, não precisas de mexer em hosts):

```bash
cd docker
./start-osb.sh
```

O script sobe `soadb` → `osbas` → `osbms` pela ordem certa, espera que cada um fique pronto
antes de avançar, e **aplica o fix obrigatório do `adapters.os_xml` nos dois momentos em que é
preciso** (antes do `osbas` e outra vez antes do `osbms`). Se algum servidor falhar, mostra as
últimas linhas do log e sai, em vez de ficar à espera indefinidamente. No fim imprime os URLs.

⚠️ **Não subas os containers só com `docker-compose up` sem o fix.** Cada servidor acrescenta
um bloco `<ldap>` ao `adapters.os_xml` ao arrancar; quem apanhar o ficheiro com 2 morre
silenciosamente (`JPS-02592` / `duplicate keys` — o container fica `Up`, mas o Java já morreu).
Depois de um arranque completo o ficheiro fica sempre com 2, por isso isto aplica-se a
**todos** os arranques. Detalhe em "Problemas comuns", no fim deste documento.

À mão, se precisares de controlar cada passo:

```bash
cd docker
source ./setenv.sh

# 1) Base de dados — espera por "DATABASE IS READY TO USE!"
docker-compose up -d soadb
docker logs -f soadb

# 2) Admin Server — como o domínio já existe, salta RCU/criação e arranca direto
./fix-adapters.sh
docker-compose up -d osbas
# acompanha pelo as.log, não pelo docker logs — ver secção 2

# 3) Managed Server — expõe as Proxy Services em :9001/:9002
./fix-adapters.sh    # o osbas acrescentou o dele: reduz a 1 outra vez
docker-compose up -d osbms
```

Com o domínio já criado, conta **~10 min** para o `osbas` chegar a `RUNNING` e outro tanto para
o `osbms` — não os 20-40 min da primeira vez, mas também não é instantâneo.

## 2. Acompanhar o progresso real (os logs)

**Não uses `docker logs -f osbas` para isto.** Esse comando só mostra o *wrapper*
(`createDomainAndStart.sh`), que diz pouco mais que "a criar domínio…" e depois fica calado. O
trabalho real — RCU, deploy das aplicações, `RUNNING mode`, e sobretudo os stack traces quando
algo falha — sai todo para o `as.log` dentro do container.

O `as.log` é o **stdout/stderr do processo Java do servidor** — o que verias no terminal se
arrancasses o WebLogic à mão com `startWebLogic.sh`. O script do container redireciona essa
saída para ficheiro.

```bash
# Admin Server (osbas)
MSYS_NO_PATHCONV=1 docker exec osbas tail -f \
  /u01/oracle/user_projects/domains/infra_domain/logs/as.log

# Managed Server (osbms)
MSYS_NO_PATHCONV=1 docker exec osbms tail -f \
  /u01/oracle/user_projects/domains/infra_domain/logs/osb_server1/ms.log
```

> O `MSYS_NO_PATHCONV=1` é obrigatório em Git Bash: sem ele o MSYS "traduz" `/u01/oracle/...`
> para `C:/Program Files/Git/u01/oracle/...` antes de entregar ao Docker, e recebes
> `cannot open '.../as.log'` com um caminho Windows estranho no meio.

### Os ficheiros de log do domínio

Todos relativos a `/u01/oracle/user_projects/domains/infra_domain/`:

| Ficheiro | O que contém |
|---|---|
| `logs/as.log` | stdout do **Admin Server** — arranque, RCU, deploys, **stack traces de falha**. É aqui que se diagnostica um arranque que não chega ao fim. |
| `logs/osb_server1/ms.log` | o mesmo, para o **Managed Server** (`osbms`) |
| `logs/aslisten.log` | o script que espera o Admin Server ficar disponível (raramente útil) |
| `servers/AdminServer/logs/AdminServer.log` | log **estruturado** do WebLogic (formato ODL, `####<data> <nível> <subsistema>`) — mais limpo para investigar runtime depois de estar RUNNING |
| `servers/AdminServer/logs/access.log` | pedidos HTTP às consolas |
| `servers/AdminServer/logs/AdminServer-diagnostic*.log` | diagnósticos internos (WLDF) — ficheiros de 10 MB cada, raramente úteis aqui |

Na prática: **`as.log`/`ms.log` para arranque e falhas**, `AdminServer.log` para runtime.

### Confirmar que arrancou

O sinal definitivo é a linha `The server started in RUNNING mode.` no `as.log`/`ms.log`. Três
formas de a apanhar:

```bash
# a) seguir ao vivo (Ctrl+C para sair)
MSYS_NO_PATHCONV=1 docker exec osbas tail -f \
  /u01/oracle/user_projects/domains/infra_domain/logs/as.log

# b) verificação rápida sim/não — 0 = ainda não, 1 = já arrancou
MSYS_NO_PATHCONV=1 docker exec osbas grep -c "RUNNING mode" \
  /u01/oracle/user_projects/domains/infra_domain/logs/as.log

# c) pela consola — 000 = ainda não aceita ligações, 302 = pronto
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:7001/console
```

`docker ps` pode mostrar `(unhealthy)` ou `(health: starting)` durante um bocado mesmo depois de
aparecer `RUNNING mode` no log — o healthcheck demora a apanhar o estado novo. Não é erro por
si só; confia no log.

Ordem de grandeza, com o domínio já criado: `soadb` fica pronta em ~2-3 min, o `osbas` demora
**~10 min** até `RUNNING` (o grosso é o deploy das aplicações do Service Bus — vais ver
Coherence e ADF Faces a inicializar perto do fim), e o `osbms` outro tanto.

## 3. Verificar que está tudo bem

```bash
docker ps --filter name=soadb --filter name=osbas --filter name=osbms
```

Os três devem aparecer `Up ... (healthy)`.

⚠️ **`Up` não quer dizer que o servidor está vivo.** Se o processo Java do WebLogic morrer
depois de arrancar (é o que acontece no problema do `duplicate keys`, ver "Problemas comuns"),
o container continua `Up` e o `docker logs` não mostra nada de anormal — mas a consola nunca
responde. Um container `Up` há muito tempo e ainda `(health: starting)` é sinal disto: vai
confirmar ao `as.log`/`ms.log`.

Confirmação definitiva (mais fiável que o healthcheck do Docker): entra no
**WebLogic Admin Console** → *Environment → Servers* e confirma que `AdminServer` e
`osb_server1` aparecem `RUNNING` / `OK`. (`osb_server2` aparece sempre `SHUTDOWN` — é normal,
este `docker-compose.yml` só cria container para `osb_server1`.)

## 4. Acessos

| O quê | URL | Credenciais |
|---|---|---|
| WebLogic Admin Console | http://localhost:7001/console | `weblogic` / o que definiste em `DC_ADMIN_PWD` (setenv.sh) |
| Service Bus Console | http://localhost:7001/servicebus | idem |
| Proxy Services (runtime) | http://localhost:9001/... (HTTP) e :9002 (HTTPS) | — |

## 5. Testar uma Proxy Service

Depois de criares uma Proxy Service na Service Bus Console (ver passo 6 do `../README.md`):

```bash
cd test
./test-proxy.sh /caminho/da/tua/proxy
```

ou importa `test/osb-test.postman_collection.json` no Postman.

## 6. Parar

```bash
cd docker
docker-compose down          # para os containers, mantém os dados (domínio + BD)
```

Não uses `docker-compose down -v` nem apagues `$DC_USERHOME` a não ser que queiras mesmo
recomeçar do zero — isso obriga a correr o RCU e a criação do domínio outra vez (20-40 min).

Um `docker-compose down` normal (sem `-v`) é seguro — os dados reais da BD Oracle vivem no
volume nomeado `osb_soadb_orcl` (declarado neste `docker-compose.yml`), que sobrevive à
remoção dos containers. **Isto só é verdade se a tua cópia do `docker-compose.yml` já tiver
essa entrada `volumes: soadb_orcl:`** — sem ela, o Docker cria um volume anónimo novo (vazio)
de cada vez que o `soadb` é recriado, e perdes as schemas RCU em silêncio (ver primeiro item
de "Problemas comuns" abaixo).

## Problemas comuns

- **`osbas` falha a arrancar com `ORA-01017: invalid username/password` no `as.log`**, mesmo
  tendo a certeza de que a password em `setenv.sh` está certa: isto não é um problema de
  password — é a schema RCU (`OSB01_OPSS`, etc.) que deixou de existir na base de dados. A
  imagem `database/enterprise` guarda os datafiles reais em `/ORCL`, um volume *anónimo*
  declarado dentro da própria imagem. Se o teu `docker-compose.yml` não tiver a entrada
  `soadb_orcl:/ORCL` (e a secção `volumes: soadb_orcl:` no fim do ficheiro), um
  `docker-compose down` + `up` recria esse volume vazio sem avisar, e a base "esquece-se" de
  tudo o que o RCU criou — mesmo continuando a arrancar normalmente e a ficar `healthy`, porque
  do ponto de vista dela é só uma base nova. Este `docker-compose.yml` já vem com o volume
  nomeado para evitar isto; se acontecer mesmo assim, confirma que a tua cópia está actualizada
  (`git pull`).
- **`/servicebus` redireciona para `errorPage.jspx`** (normalmente ao tentar fazer login, não
  necessariamente ao carregar a página inicial): confirma no `as.log` (ver secção 2) se há
  `java.net.URISyntaxException: Malformed IPv6 address at index 8: ldap://[172.20.0.x]:7001`.
  É um bug de incompatibilidade entre o JDK 8 mais recente incluído na imagem e código antigo
  do FMW (`libOVD`/`ArisID`) que envolve endereços IPv4 em `[]` como se fossem IPv6 ao construir
  URLs LDAP para o identity store embutido. `EXTRA_JAVA_PROPERTIES=-Djava.net.preferIPv4Stack=true`
  (já definido em `osbas`/`osbms`) **não chega sozinho** — só evita alguns casos, mas o login em
  si continua a falhar. O fix real é editar a config do OVD para deixar de usar o IP dinâmico do
  container:

  ```bash
  MSYS_NO_PATHCONV=1 docker exec osbas sed -i \
    's|<host percentage="100" port="-1" readonly="false">%HOST%</host>|<host percentage="100" port="-1" readonly="false">localhost</host>|' \
    /u01/oracle/user_projects/domains/infra_domain/config/fmwconfig/ovd/default/adapters.os_xml
  docker restart osbas
  ```

  Isto troca o macro `%HOST%` (que se resolve para o IP dinâmico do container, ex:
  `172.20.0.3` — daí o "endereço IPv6 malformado") por `localhost`, que é correto neste caso: é
  o identity store embutido do próprio WebLogic, self-referencing, não precisa de ser
  alcançável a partir de outros containers. Como isto vive no domínio (bind mount), só precisas
  de fazer isto **uma vez** — sobrevive a `docker-compose down`/`up` normais. Confirmado por
  login real (POST a `j_security_check`), não só por a página inicial carregar.
- **`osbas` ou `osbms` morre no arranque com `JPS-02592` / `duplicate keys`** — este é o
  problema mais chato deste setup, porque **volta a acontecer sozinho**. No `as.log`/`ms.log`:

  ```
  SEVERE: Failed to push ldap config data to libOvd for service instance "idstore.ldap"
  oracle.xml.parser.v2.XMLParseException; Identity constraint validation error: 'duplicate keys'
  <BEA-000365> <Server state changed to FAILED.>
  <BEA-000383> <A critical service failed. The server will shut itself down.>
  ```

  O container fica `Up` (e o `docker logs` não mostra nada de estranho) mas o processo Java já
  se suicidou — a consola nunca responde.

  **O mecanismo** (confirmado em execução): no arranque, cada servidor lê o
  `adapters.os_xml` e **acrescenta-lhe um bloco `<ldap id="DefaultAuthenticator">`**. Como os
  dois containers partilham o mesmo domínio (o bind mount `$DC_USERHOME/osbdomain`), escrevem
  ambos no mesmo ficheiro. Dois blocos com o mesmo `id` violam uma constraint de chave única do
  schema, e o servidor que apanhar o ficheiro já com 2 rebenta antes de o OPSS arrancar. Na
  prática:

  | Blocos no ficheiro ao arrancar | Resultado |
  |---|---|
  | 0 ou 1 | arranca bem — e deixa o ficheiro com +1 bloco |
  | 2 ou mais | `duplicate keys` → `FAILED` |

  Ou seja: depois de um arranque completo bem sucedido (`osbas` + `osbms`), o ficheiro fica com
  **2 blocos** — e o arranque *seguinte* falha logo no `osbas`. Não é uma corrupção pontual, é
  o comportamento normal deste ambiente.

  **A correção**, se já estás com um servidor em baixo:

  ```bash
  cd docker
  ./fix-adapters.sh                  # reduz a 1 bloco (faz backup em adapters.os_xml.bak)
  docker-compose restart osbas       # ou osbms, conforme o que falhou
  ```

  O `fix-adapters.sh` é idempotente — se o ficheiro já estiver bem, diz-te e não mexe. Para
  veres o estado sem corrigir:

  ```bash
  grep -c "<ldap id=" \
    "$DC_DDIR_OSB/domains/infra_domain/config/fmwconfig/ovd/default/adapters.os_xml"
  ```

  **Para não voltar a acontecer:** usa o `./start-osb.sh` (secção 1) em vez de `docker-compose
  up` à mão — ele chama o `fix-adapters.sh` nos dois momentos necessários. Se subires à mão,
  lembra-te de correr o fix **duas vezes**: antes do `osbas`, e outra vez antes do `osbms` (o
  `osbas` acabou de acrescentar o bloco dele).

  Nota: o `sed` do fix do IPv6 (acima) é idempotente e **não** causa isto — podes corrê-lo mais
  do que uma vez sem problema. É o próprio FMW que acrescenta os blocos.
- **`osbms` preso em "Waiting for the Managed Server to accept requests..."**: confirma no
  `ms.log` se há `Enter username to boot WebLogic server` seguido de `shutdown hook` — significa
  que falta `ADMIN_PASSWORD` no serviço `osbms`.
- **`osbms` sempre `(unhealthy)` mesmo com `RUNNING mode` no log**: o healthcheck da imagem
  verifica a porta errada se faltar `MANAGED_SERVER_CONTAINER=true` e `MANAGEDSERVER_PORT=9001`
  no ambiente do serviço.
